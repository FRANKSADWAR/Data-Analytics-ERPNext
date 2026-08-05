-- Total amount owed to suppliers
WITH
  payables_gl AS (
    SELECT
      `tabGL Entry`.name,
      `tabGL Entry`.posting_date,
      `tabGL Entry`.account,
      `tabGL Entry`.party_type,
      `tabGL Entry`.party,
      sp.supplier_name,
      `tabGL Entry`.debit,
      `tabGL Entry`.credit
    FROM
      `tabGL Entry`
      LEFT JOIN `tabAccount` ON `tabGL Entry`.account = `tabAccount`.name
      LEFT JOIN `tabSupplier` AS sp ON `tabGL Entry`.party = sp.name
    WHERE
      `tabGL Entry`.is_cancelled = 0
      AND `tabAccount`.account_type = 'Payable'
  ),
  invoices_and_payments AS (
    SELECT
      party,
      supplier_name,
      SUM(credit) AS supplier_invoices,
      SUM(debit) AS supplier_payments
    FROM
      payables_gl
    GROUP BY
      party,
      supplier_name
    ORDER BY
      supplier_invoices DESC
  ),
  
  payable_amount AS (
    SELECT
    party,
    supplier_name,
    supplier_invoices - supplier_payments AS supplier_balances
    FROM invoices_and_payments
    WHERE (supplier_invoices - supplier_payments) > 0
  )
  
  SELECT SUM(supplier_balances) FROM payable_amount



-- Get the payables agening report
WITH 
    -- Purchase invoices credit a supplier
    purchase_invoice_list AS (
        SELECT
            `tabPurchase Invoice`.name,
            `tabPurchase Invoice`.supplier AS supplier_id,
            `tabPurchase Invoice`.supplier_name,
            `tabPurchase Invoice`.posting_date,
            `tabPurchase Invoice`.due_date,
            `tabPurchase Invoice`.base_grand_total, 
            `tabPurchase Invoice`.party_account_currency,
            `tabPurchase Invoice`.outstanding_amount,
            CASE
                WHEN `tabPurchase Invoice`.party_account_currency = 'USD' THEN `tabPurchase Invoice`.outstanding_amount * `tabPurchase Invoice`.conversion_rate
                ELSE `tabPurchase Invoice`.outstanding_amount
            END AS outstanding_amount_converted,
            DATEDIFF({{ due_date }}, `tabPurchase Invoice`.due_date) AS days_after_due_date
        FROM `tabPurchase Invoice`
        LEFT JOIN `tabSupplier` AS su ON `tabPurchase Invoice`.supplier = su.name
        WHERE
            `tabPurchase Invoice`.docstatus = 1 
            AND `tabPurchase Invoice`.status NOT IN ('Paid','Return')
            AND DATEDIFF({{due_date}}, `tabPurchase Invoice`.due_date) >= 0
    ),

    -- Include categorization for the days range
    purchase_invoices_ageing AS (
        SELECT
            supplier_id,
            supplier_name,
            COALESCE(SUM(CASE WHEN days_after_due_date BETWEEN 0 AND 30 THEN outstanding_amount_converted ELSE 0 END),0) AS "0-30",
            COALESCE(SUM(CASE WHEN days_after_due_date BETWEEN 31 AND 60 THEN outstanding_amount_converted ELSE 0 END),0) AS "31-60",
            COALESCE(SUM(CASE WHEN days_after_due_date BETWEEN 61 AND 90 THEN outstanding_amount_converted ELSE 0 END),0) AS "61-90",
            COALESCE(SUM(CASE WHEN days_after_due_date BETWEEN 91 AND 120 THEN outstanding_amount_converted ELSE 0 END),0) AS "91-120",
            COALESCE(SUM(CASE WHEN days_after_due_date >= 121 THEN outstanding_amount_converted ELSE 0 END),0) AS "121-Above",
            SUM(outstanding_amount_converted) AS Outstanding_From_Invoices
        FROM purchase_invoice_list
        GROUP BY supplier_id
    ),
    
    
    -- Get the unallocated payments to suppliers from payment entry 
    unallocated_payment_entries AS (
        SELECT 
            name, 
            payment_type,
            posting_date, 
            party_type,
            party,
            party_name,
            base_received_amount,
            base_paid_amount,
            base_total_allocated_amount,
            (base_paid_amount - base_total_allocated_amount) AS base_unallocated_amount
        FROM `tabPayment Entry`
        WHERE
            docstatus = 1 
            AND payment_type = 'Pay'
            AND party_type = 'Supplier'
            AND (base_paid_amount - base_total_allocated_amount) > 0
    ),
    
    unallocated_payment_entry_summary AS (
        SELECT 
            party AS supplier_id,
            party_name AS supplier_name,
            SUM(base_unallocated_amount) AS total_unallocated_amount
        FROM unallocated_payment_entries
        GROUP BY party
    ),

    
    balances_from_gl AS (
        SELECT
        `tabGL Entry`.name,
        `tabGL Entry`.posting_date,
        `tabGL Entry`.account,
        `tabGL Entry`.party_type,
        `tabGL Entry`.party,
        sp.supplier_name,
        `tabGL Entry`.voucher_type,
        `tabGL Entry`.credit,
        `tabGL Entry`.debit
        FROM `tabGL Entry`
            LEFT JOIN `tabSupplier` AS sp ON `tabGL Entry`.party = sp.name
        WHERE `tabGL Entry`.docstatus = 1
            AND `tabGL Entry`.voucher_type = 'Journal Entry'
            AND `tabGL Entry`.is_cancelled = 0
            AND `tabGL Entry`.party_type = 'Supplier'
    ),
    
    -- Get the summary of the balances from the Journal Entry Vouchers
    balances_from_gl_summary AS (
        SELECT
            party AS supplier_id,
            supplier_name,
            (SUM(credit) - SUM(debit)) AS balance_amount_from_gl
        FROM balances_from_gl 
        GROUP BY party
    ),
    
    -- Because we are not filtering the Opening entries, we have to consider payment entries that have been allocated
    allocated_journal_payments AS (
        SELECT 
        `tabPayment Entry Reference`.name,
        `tabPayment Entry Reference`.reference_doctype,
        `tabPayment Entry Reference`.reference_name,
        `tabPayment Entry Reference`.total_amount,
        `tabPayment Entry Reference`.outstanding_amount,
        `tabPayment Entry Reference`.allocated_amount,
        pe.party_type,
        pe.party,
        pe.party_name
        FROM `tabPayment Entry Reference` 
            INNER JOIN `tabPayment Entry` AS pe ON `tabPayment Entry Reference`.parent = pe.name
            WHERE reference_doctype = 'Journal Entry'
            AND pe.payment_type = 'Pay'
            AND pe.docstatus = 1
    ),
    
    -- Now we should combine the balances now so that we get one figure
    allocated_journals_summary AS (
        SELECT 
            party AS supplier_id,
            party_name AS supplier_name, 
            (SUM(allocated_amount) * -1)  AS sum_already_allocated 
        FROM allocated_journal_payments 
        GROUP BY party
    ),
    
    
    -- Combine the balance from GLs and the allocated journals using a UNION ALL
    allocated_journals_and_gl_balances_list AS (
        SELECT supplier_id, supplier_name, sum_already_allocated  FROM allocated_journals_summary
        UNION ALL
        SELECT supplier_id, supplier_name, balance_amount_from_gl FROM balances_from_gl_summary
    ),
    
    
    outstanding_amounts_union AS (
        SELECT supplier_id, supplier_name, actual_bal FROM purchase_invoices_ageing
        UNION ALL
        SELECT supplier_id, supplier_name, actual_bal FROM allocated_journals_and_gl_balances
    )
   
  
    SELECT * FROM allocated_journals_and_gl_balances_list
    

-- Final approach to get the Accounts Payable Aging Report
WITH 
    -- START WITH THE CREDITS
    
    -- Purchase invoices credited to the supplier
    purchase_invoice_list AS (
        SELECT
            `tabPurchase Invoice`.name,
            `tabPurchase Invoice`.supplier AS supplier_id,
            `tabPurchase Invoice`.supplier_name,
            `tabPurchase Invoice`.posting_date,
            `tabPurchase Invoice`.due_date,
            `tabPurchase Invoice`.base_grand_total, 
            `tabPurchase Invoice`.party_account_currency,
            `tabPurchase Invoice`.outstanding_amount,
            CASE
                WHEN `tabPurchase Invoice`.party_account_currency = 'USD' THEN `tabPurchase Invoice`.outstanding_amount * `tabPurchase Invoice`.conversion_rate
                ELSE `tabPurchase Invoice`.outstanding_amount
            END AS outstanding_amount_converted,
            DATEDIFF({{ due_date }}, `tabPurchase Invoice`.due_date) AS days_after_due_date
        FROM `tabPurchase Invoice`
        LEFT JOIN `tabSupplier` AS su ON `tabPurchase Invoice`.supplier = su.name
        WHERE
            `tabPurchase Invoice`.docstatus = 1 
            AND `tabPurchase Invoice`.status NOT IN ('Paid','Return')
            AND DATEDIFF({{due_date}}, `tabPurchase Invoice`.due_date) >= 0
    ),

    -- Include categorization for the days range
    purchase_invoices_ageing AS (
        SELECT
            supplier_id,
            supplier_name,
            COALESCE(SUM(CASE WHEN days_after_due_date BETWEEN 0 AND 30 THEN outstanding_amount_converted ELSE 0 END),0) AS "0-30",
            COALESCE(SUM(CASE WHEN days_after_due_date BETWEEN 31 AND 60 THEN outstanding_amount_converted ELSE 0 END),0) AS "31-60",
            COALESCE(SUM(CASE WHEN days_after_due_date BETWEEN 61 AND 90 THEN outstanding_amount_converted ELSE 0 END),0) AS "61-90",
            COALESCE(SUM(CASE WHEN days_after_due_date BETWEEN 91 AND 120 THEN outstanding_amount_converted ELSE 0 END),0) AS "91-120",
            COALESCE(SUM(CASE WHEN days_after_due_date >= 121 THEN outstanding_amount_converted ELSE 0 END),0) AS "121-Above",
            SUM(outstanding_amount_converted) AS Outstanding_From_Invoices
        FROM purchase_invoice_list
        GROUP BY supplier_id
    ),
    
    -- Now we get the credits done to the supplier but using Journal Entries, basically they do not have a reference type
    journal_credits_list AS (
        SELECT
            `tabJournal Entry`.posting_date,
            `tabJournal Entry Account`.name,
            `tabJournal Entry Account`.party_type,
            `tabJournal Entry Account`.party,
            `tabJournal Entry Account`.account,
            `tabJournal Entry Account`.against_account,
            sp.supplier_name,
            `tabJournal Entry Account`.debit,
            `tabJournal Entry Account`.credit,
            `tabJournal Entry Account`.reference_type,
            `tabJournal Entry Account`.reference_name,
            `tabJournal Entry Account`.parent,
            `tabJournal Entry Account`.parentfield,
            `tabJournal Entry Account`.bank_account,
            `tabJournal Entry Account`.account_type
        FROM `tabJournal Entry Account`
            INNER JOIN `tabJournal Entry` ON `tabJournal Entry Account`.parent = `tabJournal Entry`.name
            INNER JOIN `tabAccount` AS acc ON `tabJournal Entry Account`.account = acc.name
            LEFT JOIN `tabSupplier` AS sp ON `tabJournal Entry Account`.party = sp.name
        WHERE
            `tabJournal Entry Account`.docstatus = 1 
            AND `tabJournal Entry`.docstatus = 1
            AND `tabJournal Entry Account`.party_type = 'Supplier'
            AND `tabJournal Entry Account`.credit > 0 -- Look at only where the supplier i.e the suppler is being credited
            AND `tabJournal Entry`.is_system_generated = 0
            AND `tabJournal Entry Account`.reference_type IS NULL
            AND `tabJournal Entry Account`.reference_name IS NULL
            AND acc.account_type = 'Payable' -- Look at all accounts that are of type Payable
            -- AND `tabJournal Entry`.reversal_of IS NULL
        ),
        
    -- Categorization of the journal entry credits into ageing: Just same as what we did with the Purchase Invoices
    journal_credits_summary AS (
        SELECT
            party AS supplier_id,
            supplier_name,
            0 AS "0-30",
            0 AS "31-60",
            0 AS "61-90",
            0 AS "91-120",
            0 AS "121-Above",
            SUM(credit) AS  Outstanding_From_Invoices
        FROM journal_credits_list 
        GROUP BY party
        
    ),
    
    -- Combine all the CREDITS INTO ONE TABLE
    total_outstanding_list AS (
        SELECT * FROM purchase_invoices_ageing
        UNION ALL
        SELECT * FROM journal_credits_summary
    ),
    
    
    -- THIS TABLE CONTAINS ALL SUPPLIER AMOUNTS I.E CREDITED AMOUNTS THAT ARE BALANCES ------------------------------------------------ CREDITS UNPAID FOR YET:
    total_outstanding_summary AS (
        SELECT
            supplier_id,
            supplier_name,
            SUM(`0-30`) AS '0-30',
            SUM(`31-60`) AS '31-60',
            SUM(`61-90`) AS '61-90',
            SUM(`91-120`) AS '91-120',
            SUM(`121-Above`) AS '121-Above',
            SUM(Outstanding_From_Invoices) AS Total_Outstanding
        FROM total_outstanding_list
        GROUP BY supplier_id
    ),
    
    
    
    -- Get the unallocated payments to suppliers from payment entry 
    unallocated_payment_entries_list AS (
        SELECT 
            name, 
            payment_type,
            posting_date, 
            party_type,
            party,
            party_name,
            base_received_amount,
            base_paid_amount,
            base_total_allocated_amount,
            (base_paid_amount - base_total_allocated_amount) AS base_unallocated_amount
        FROM `tabPayment Entry`
        WHERE
            docstatus = 1 
            AND payment_type = 'Pay'
            AND party_type = 'Supplier'
            AND (base_paid_amount - base_total_allocated_amount) > 0
    ),
    
    -- Sum of payment entries that have not been allocated to a purchase invoice or journal entry
    unallocated_payment_entry_summary AS (
        SELECT 
            party AS supplier_id,
            party_name AS supplier_name,
            SUM(base_unallocated_amount) AS total_unallocated_amount
        FROM unallocated_payment_entries_list
        GROUP BY party
    ),
    
    -- Now we get the journal entry with debits that have not been allocated to any purchase or journal entry
    unallocated_journal_debits_list AS (
        SELECT
            `tabJournal Entry`.posting_date,
            `tabJournal Entry Account`.name,
            `tabJournal Entry Account`.party_type,
            `tabJournal Entry Account`.party,
            `tabJournal Entry Account`.account,
            `tabJournal Entry Account`.against_account,
            sp.supplier_name,
            `tabJournal Entry Account`.debit,
            `tabJournal Entry Account`.credit,
            `tabJournal Entry Account`.reference_type,
            `tabJournal Entry Account`.reference_name,
            `tabJournal Entry Account`.parent,
            `tabJournal Entry Account`.parentfield,
            `tabJournal Entry Account`.bank_account,
            `tabJournal Entry Account`.account_type
        FROM `tabJournal Entry Account`
            INNER JOIN `tabJournal Entry` ON `tabJournal Entry Account`.parent = `tabJournal Entry`.name
            INNER JOIN `tabAccount` AS acc ON `tabJournal Entry Account`.account = acc.name
            LEFT JOIN `tabSupplier` AS sp ON `tabJournal Entry Account`.party = sp.name
        WHERE
            `tabJournal Entry Account`.docstatus = 1 
            AND `tabJournal Entry`.docstatus = 1
            AND `tabJournal Entry Account`.party_type = 'Supplier'
            AND `tabJournal Entry Account`.debit > 0 -- Look at only where the is being debited (i.e being paid through the Journal entry)
            AND `tabJournal Entry`.is_system_generated = 0
            AND `tabJournal Entry Account`.reference_type IS NULL
            AND acc.account_type = 'Payable' -- Look at all accounts that are of type Payable
    ),
    
    unallocated_debits_summary AS (
        SELECT
            party AS supplier_id,
            supplier_name,
            SUM(debit) AS debits_unallocated
        FROM unallocated_journal_debits_list
        GROUP BY party
            
    ),
    
    
    unallocated_amount_list AS (
        SELECT * FROM unallocated_payment_entry_summary
        UNION ALL 
        SELECT * FROM unallocated_debits_summary
    ),
    
    
    -- TOTAL UNALLOCATED AMOUNTS ----------------------------------------------------------------------- UNALLOCATED AMOUNTS ARE HERE
    unallocated_amounts_summary AS (
        SELECT 
            supplier_id,
            supplier_name,
            SUM(total_unallocated_amount) AS total_amount_unallocated
        FROM unallocated_amount_list
        GROUP BY supplier_id
    ),
    
    
    -- Get the allocated payments to Journal Entries from Payment entry reference table
    allocated_journal_payments AS (
        SELECT 
        `tabPayment Entry Reference`.name,
        `tabPayment Entry Reference`.reference_doctype,
        `tabPayment Entry Reference`.reference_name,
        `tabPayment Entry Reference`.total_amount,
        `tabPayment Entry Reference`.outstanding_amount,
        `tabPayment Entry Reference`.allocated_amount,
        pe.party_type,
        pe.party,
        pe.party_name
        FROM `tabPayment Entry Reference` 
            INNER JOIN `tabPayment Entry` AS pe ON `tabPayment Entry Reference`.parent = pe.name
            WHERE `tabPayment Entry Reference`.reference_doctype = 'Journal Entry'
            AND pe.payment_type = 'Pay'
            AND pe.docstatus = 1
            AND pe.party_type = 'Supplier'
    ),
    
    -- Summarize the payments linked to journal entries from payment entry reference::::: SUMMARY OF PAYMENT ENTRIES ALREADY ALLOCATED TO JOURNAL ENTRIES ONLY
    allocated_journal_payment_summary AS (
        SELECT 
            party AS supplier_id,
            party_name AS supplier_name, 
            (SUM(allocated_amount))  AS debits_allocated 
        FROM allocated_journal_payments 
        GROUP BY party
    ),
    
    -- Get the allocated payments to Journal entries but from Journal entry debits
    allocated_journal_debits_list AS (
        SELECT
            `tabJournal Entry`.posting_date,
            `tabJournal Entry Account`.name,
            `tabJournal Entry Account`.party_type,
            `tabJournal Entry Account`.party,
            `tabJournal Entry Account`.account,
            `tabJournal Entry Account`.against_account,
            sp.supplier_name,
            `tabJournal Entry Account`.debit,
            `tabJournal Entry Account`.credit,
            `tabJournal Entry Account`.reference_type,
            `tabJournal Entry Account`.reference_name,
            `tabJournal Entry Account`.parent,
            `tabJournal Entry Account`.parentfield,
            `tabJournal Entry Account`.bank_account,
            `tabJournal Entry Account`.account_type
        FROM `tabJournal Entry Account`
            INNER JOIN `tabJournal Entry` ON `tabJournal Entry Account`.parent = `tabJournal Entry`.name
            INNER JOIN `tabAccount` AS acc ON `tabJournal Entry Account`.account = acc.name
            LEFT JOIN `tabSupplier` AS sp ON `tabJournal Entry Account`.party = sp.name
        WHERE
            `tabJournal Entry Account`.docstatus = 1 
            AND `tabJournal Entry`.docstatus = 1
            AND `tabJournal Entry Account`.party_type = 'Supplier'
            AND `tabJournal Entry Account`.debit > 0 -- Look at only where the is being debited (i.e being paid through the Journal entry)
            AND `tabJournal Entry`.is_system_generated = 0
            AND `tabJournal Entry Account`.reference_type IS NOT NULL
            AND `tabJournal Entry Account`.reference_type <> 'Purchase Invoice'
            AND acc.account_type = 'Payable' -- Look at all accounts that are of type Payable
    ),
    
    journal_debits_summary AS (
        SELECT
            party AS supplier_id,
            supplier_name,
            SUM(debit) AS debits_allocated
        FROM allocated_journal_debits_list
        GROUP BY party
    ),
    
    
    allocated_journals_and_payments_list AS (
        SELECT * FROM journal_debits_summary
        UNION ALL
        SELECT * FROM allocated_journal_payment_summary
        
    ),
    -- SUMMARY OF ALL PAYMENTS ROM PAYMENT ENTRY AND JOURNAL ENTRY THAT HAVE BEEN USED TO REDUCE THE BALANCES FROM JOURNAL ENTRIES
    sum_allocated_journals_and_payments AS (
        SELECT
            supplier_id,
            supplier_name,
            SUM(debits_allocated) AS total_debits_allocated
        FROM allocated_journals_and_payments_list
        GROUP BY supplier_id
    ),
    
    
    -- Put all payments together and subtract them from outstanding amount once
    payments_table_list AS (
        SELECT * FROM unallocated_amounts_summary
        UNION ALL
        SELECT * FROM sum_allocated_journals_and_payments
    ),
    
    payments_summary_table AS (
        SELECT 
            supplier_id, 
            supplier_name, SUM(total_amount_unallocated) AS total_debits 
        FROM payments_table_list
        GROUP BY supplier_id
    ),
    
    accounts_payable_table AS (
        SELECT 
            total_outstanding_summary.supplier_id,
            total_outstanding_summary.supplier_name,
            total_outstanding_summary.`0-30`,
            total_outstanding_summary.`31-60`,
            total_outstanding_summary.`61-90`,
            total_outstanding_summary.`91-120`,
            total_outstanding_summary.`121-Above`,
            IFNULL(payments_summary_table.total_debits,0) AS Unallocated_Amount,
            total_outstanding_summary.Total_Outstanding,
            (IFNULL(total_outstanding_summary.Total_Outstanding,0) - IFNULL(payments_summary_table.total_debits,0)) AS Balance
        FROM total_outstanding_summary
            LEFT JOIN payments_summary_table ON total_outstanding_summary.supplier_id = payments_summary_table.supplier_id
    )
    
    SELECT * FROM accounts_payable_table WHERE Balance > 0 ORDER BY Balance DESC
    
    
-- Get the total amount owed to suppliers (irrespective of the ageing)
WITH
  payables_gl AS (
    SELECT
      `tabGL Entry`.name,
      `tabGL Entry`.posting_date,
      `tabGL Entry`.account,
      `tabGL Entry`.party_type,
      `tabGL Entry`.party,
      sp.supplier_name,
      `tabGL Entry`.debit,
      `tabGL Entry`.credit
    FROM
      `tabGL Entry`
      LEFT JOIN `tabAccount` ON `tabGL Entry`.account = `tabAccount`.name
      LEFT JOIN `tabSupplier` AS sp ON `tabGL Entry`.party = sp.name
    WHERE
      `tabGL Entry`.is_cancelled = 0
      AND `tabAccount`.account_type = 'Payable'
  ),
  invoices_and_payments AS (
    SELECT
      party,
      supplier_name,
      SUM(credit) AS supplier_invoices,
      SUM(debit) AS supplier_payments
    FROM
      payables_gl
    GROUP BY
      party,
      supplier_name
    ORDER BY
      supplier_invoices DESC
  ),
  
  payable_amount AS (
    SELECT
    party,
    supplier_name,
    supplier_invoices - supplier_payments AS supplier_balances
    FROM invoices_and_payments
    
  )
  
  SELECT
    SUM(supplier_balances) AS total_owed
    FROM payable_amount
    WHERE supplier_balances > 0

-- Get customer balance from GL Entry
WITH transactions AS (
  SELECT
      party,
      party_type,
      transaction_currency,
      debit_in_transaction_currency,
      credit_in_transaction_currency
    FROM
      `tabGL Entry`
    WHERE
      party = 'CUST-2025-00033'
      AND is_cancelled = 0
)
SELECT party, transaction_currency, (SUM(debit_in_transaction_currency) - SUM(credit_in_transaction_currency)) AS balance FROM transactions GROUP BY party

-- Amount received from customers during a period
WITH
    -- Get the total amount collected during the period
    received_amounts_from_customers AS (
        SELECT
            `tabGL Entry`.posting_date,
            `tabGL Entry`.account,
            `tabGL Entry`.debit,
            `tabGL Entry`.credit,
            `tabGL Entry`.against,
            `tabGL Entry`.party_type,
            customer.customer_name,
            `tabGL Entry`.voucher_type,
            `tabGL Entry`.voucher_no,
            `tabGL Entry`.voucher_subtype,
            `tabGL Entry`.against_voucher_type,
            `tabGL Entry`.against_voucher
        FROM `tabGL Entry`
            INNER JOIN `tabAccount` AS acc ON `tabGL Entry`.account = acc.name
            INNER JOIN `tabCustomer` AS customer ON `tabGL Entry`.against = customer.name
        WHERE acc.account_type IN ('Bank','Cash')
            AND `tabGL Entry`.is_cancelled = 0
            AND `tabGL Entry`.voucher_subtype IN ('Journal Entry','Receive')
            AND `tabGL Entry`.posting_date BETWEEN '2026-07-01' AND '2026-07-31'
            AND `tabGL Entry`.account NOT IN ('Suspense Account NML')
            AND `tabGL Entry`.debit > 0
    ),
    
    -- summarize the collected amount during the period
    collected_amount_summary AS (
        SELECT 
            account AS account_name, 
            SUM(debit) AS money_in 
        FROM received_amounts_from_customers 
        GROUP BY account
    )
    
-- Amount paid to suppliers during a period
WITH
    -- Get the total amount paid to suppliers during the period
    amount_paid_to_suppliers AS (
        SELECT
            `tabGL Entry`.posting_date,
            `tabGL Entry`.account,
            `tabGL Entry`.debit,
            `tabGL Entry`.credit,
            `tabGL Entry`.against,
            `tabGL Entry`.party_type,
            supplier.supplier_name,
            `tabGL Entry`.parent_account,
            `tabGL Entry`.voucher_type,
            `tabGL Entry`.voucher_no,
            `tabGL Entry`.voucher_subtype,
            `tabGL Entry`.against_voucher_type,
            `tabGL Entry`.against_voucher
        FROM `tabGL Entry`
            INNER JOIN `tabAccount` AS acc ON `tabGL Entry`.account = acc.name
            INNER JOIN `tabSupplier` AS supplier ON `tabGL Entry`.against = supplier.name
        WHERE acc.account_type IN ('Bank','Cash')
            AND `tabGL Entry`.is_cancelled = 0
            AND `tabGL Entry`.voucher_subtype IN ('Journal Entry','Pay')
            AND `tabGL Entry`.posting_date BETWEEN '2026-07-01' AND '2026-07-31'
            AND `tabGL Entry`.account NOT IN ('Suspense Account NML')
            AND `tabGL Entry`.credit > 0
    )
    
    SELECT * FROM amount_paid_to_suppliers


-- Cash flow mapping in and out of the business
WITH
    -- Get the total amount collected during the period
    received_amounts_from_customers AS (
        SELECT
            `tabGL Entry`.posting_date,
            `tabGL Entry`.account,
            `tabGL Entry`.debit,
            `tabGL Entry`.credit,
            `tabGL Entry`.against,
            `tabGL Entry`.party_type,
            customer.customer_name,
            `tabGL Entry`.voucher_type,
            `tabGL Entry`.voucher_no,
            `tabGL Entry`.voucher_subtype,
            `tabGL Entry`.against_voucher_type,
            `tabGL Entry`.against_voucher
        FROM `tabGL Entry`
            INNER JOIN `tabAccount` AS acc ON `tabGL Entry`.account = acc.name
            INNER JOIN `tabCustomer` AS customer ON `tabGL Entry`.against = customer.name
        WHERE acc.account_type IN ('Bank','Cash')
            AND `tabGL Entry`.is_cancelled = 0
            AND `tabGL Entry`.voucher_subtype IN ('Journal Entry','Receive')
            AND `tabGL Entry`.posting_date BETWEEN {{ start_date }} AND {{ end_date }}
            AND `tabGL Entry`.account NOT IN ('Suspense Account NML')
            AND `tabGL Entry`.debit > 0
    ),
    
    -- summarize the collected amount during the period
    collected_amount_summary AS (
        SELECT 
            account AS account_name, 
            SUM(debit) AS amount 
        FROM received_amounts_from_customers 
        GROUP BY account
    ),
    
    -- Get the total amount paid to suppliers during the period
    payroll_party_accounts AS (
        SELECT
            `tabSupplier`.name AS supplier_id, 
            `tabSupplier`.supplier_name,
            `tabParty Account`.account AS party_account,
            `tabAccount`.parent_account
        FROM `tabSupplier`
            INNER JOIN `tabParty Account` ON `tabSupplier`.name = `tabParty Account`.parent
            INNER JOIN `tabAccount` ON `tabAccount`.name = `tabParty Account`.account
        WHERE 
            `tabAccount`.parent_account LIKE '%Payroll%'
    
    ),
    
    amount_paid_to_suppliers AS (
        SELECT
            `tabGL Entry`.posting_date,
            `tabGL Entry`.account,
            `tabGL Entry`.debit,
            `tabGL Entry`.credit,
            `tabGL Entry`.against,
            supplier.supplier_name,
            `tabGL Entry`.voucher_type,
            `tabGL Entry`.voucher_no,
            `tabGL Entry`.voucher_subtype,
            payroll_party_accounts.parent_account
        FROM `tabGL Entry`
            INNER JOIN `tabAccount` AS acc ON `tabGL Entry`.account = acc.name
            INNER JOIN `tabSupplier` AS supplier ON `tabGL Entry`.against = supplier.name
            LEFT JOIN payroll_party_accounts ON `tabGL Entry`.against = payroll_party_accounts.supplier_id
        WHERE acc.account_type IN ('Bank','Cash')
            AND `tabGL Entry`.is_cancelled = 0
            AND `tabGL Entry`.voucher_subtype IN ('Journal Entry','Pay')
            AND `tabGL Entry`.posting_date BETWEEN '2026-07-01' AND '2026-07-31'
            AND `tabGL Entry`.account NOT IN ('Suspense Account NML')
            AND `tabGL Entry`.credit > 0
    ),
    
    supplier_payments_list AS (
        SELECT
            posting_date,
            account,
            debit,
            credit,
            against,
            supplier_name,
            CASE 
                WHEN parent_account ='2500 - Payroll Liabilities - NML' THEN "Salary Payment" 
                ELSE "Supplier Payment" 
            END AS Supplier_category,
            voucher_type,
            voucher_no,
            voucher_subtype
        FROM amount_paid_to_suppliers
    ),
    
    collections_table AS (
        SELECT
            "Cash From Collections" AS Cash_Flow_Category,
            account_name,
            amount
        FROM collected_amount_summary
        
    ),
    
    cash_outflow_list AS (
        SELECT
            "Cash Outflow" AS Cash_Flow_Category,
            Supplier_category, 
            SUM(credit) AS amount
        FROM supplier_payments_list 
        GROUP BY Supplier_category
    ),
    
    other_drawings AS (
        SELECT
            `tabGL Entry`.posting_date,
            `tabGL Entry`.account,
            `tabGL Entry`.debit,
            `tabGL Entry`.credit,
            `tabGL Entry`.against,
            -- supplier.supplier_name,
            `tabGL Entry`.voucher_type,
            `tabGL Entry`.voucher_no,
            `tabGL Entry`.voucher_subtype,
            supplier.supplier_name
        FROM `tabGL Entry`
            INNER JOIN `tabAccount` AS acc ON `tabGL Entry`.account = acc.name
            LEFT JOIN `tabSupplier` AS supplier ON `tabGL Entry`.against = supplier.name
            
        WHERE acc.account_type IN ('Bank','Cash')
            AND `tabGL Entry`.is_cancelled = 0
            AND `tabGL Entry`.voucher_subtype NOT IN ('Internal Transfer')
            AND `tabGL Entry`.posting_date BETWEEN '2026-07-01' AND '2026-07-31'
            AND `tabGL Entry`.account NOT IN ('Suspense Account NML')
            AND `tabGL Entry`.credit > 0
            
    ),
    
    grouped_drawing AS (
        SELECT against, 
            SUM(credit) AS draw_amount 
        FROM other_drawings 
            WHERE supplier_name IS NULL
            AND against NOT IN ('04003101171250 I&M BANK KES A/C - NML')
        GROUP BY against
    ),
    
    other_drawing_amounts AS (
        SELECT
            "Other drawings" AS Cash_Flow_Category, 
            against AS account_name, 
            draw_amount AS amount 
        FROM grouped_drawing
    ),
    
    cash_flow_table AS (
        SELECT * FROM collections_table
        UNION ALL 
        SELECT * FROM cash_outflow_list
        UNION ALL
        SELECT * FROM other_drawing_amounts
    ),
    
    deficit_table AS (
        SELECT "Balance/Deficit" AS Totals,
            SUM(CASE WHEN Cash_Flow_Category = 'Cash From Collections' THEN amount ELSE 0 END) AS collections, 
            SUM(CASE WHEN Cash_Flow_Category = 'Cash Outflow'  THEN amount ELSE 0 END) AS Supplier_payments, 
            SUM(CASE WHEN Cash_Flow_Category = 'Other drawings'  THEN amount ELSE 0 END) AS other_drawings
        FROM cash_flow_table
            GROUP BY Totals
    )
    -- Visualised using a Sankey chart / diagram
    SELECT * FROM cash_flow_table


-- COMPUTE INCOME AND EXPENSES FOR A PERIOD USING THE ACCOUNT TYPE
WITH
  income_and_expenses AS (
    SELECT
      `tabGL Entry`.posting_date,
      `tabGL Entry`.debit,
      `tabGL Entry`.credit,
      `tabGL Entry`.account,
      acc.parent_account,
      acc.root_type,
      acc.is_group
    FROM
      `tabGL Entry`
      INNER JOIN `tabAccount` AS acc ON `tabGL Entry`.account = acc.name
    WHERE
      acc.root_type  IN ('Income','Expense')
      AND `tabGL Entry`.is_cancelled = 0
      AND `tabGL Entry`.posting_date BETWEEN '2026-07-01' AND '2026-07-31'
    ),
    
    expense_and_income_table AS (
        SELECT
           "NEVIRA MINERALS LIMITED" AS company,
            parent_account,
            SUM(CASE WHEN root_type = 'Expense' THEN (debit - credit) END) AS total_expenses,
            SUM(CASE WHEN root_type = 'Income' THEN (credit - debit) END) AS total_income
        FROM income_and_expenses 
        GROUP BY parent_account
    )
    
    SELECT 
        company, 
        "Net Profit" AS Account,
        (SUM(total_income)- SUM(total_expenses)) AS Net_Profit,
        "" AS Account_type
    FROM expense_and_income_table
    

-- Compute the cumulative sales revenue per day
SELECT
    posting_date,
    SUM(base_grand_total) AS daily_sales,
    (135000000/31) AS daily_sales_target,
    SUM(SUM(base_grand_total)) OVER(ORDER BY posting_date) AS cumulative_sales
FROM `tabSales Invoice`
WHERE 
    docstatus = 1
    AND MONTH(posting_date) = MONTH(CURDATE())
    AND YEAR(posting_date) = YEAR(CURDATE())
    AND status NOT IN ('Return')
GROUP BY posting_date
ORDER BY posting_date ASC

CREATE TABLE IF NOT EXISTS customers (
    customer_id INT PRIMARY KEY AUTO_INCREMENT,
    customer_namename VARCHAR(150),
    phone_number VARCHAR(150),
    email_address VARCHAR(150),
    country VARCHAR(150),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE IS NOT EXISTS products (
    product_sku INT PRIMARY_KEY AUTO_INCREMENT,
    product_name VARCHAR(150),
    unit_price DOUBLE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);