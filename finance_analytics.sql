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