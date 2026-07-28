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
    
    
    
    