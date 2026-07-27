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