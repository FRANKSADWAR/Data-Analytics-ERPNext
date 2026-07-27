-- Daily sales revenue
WITH
  sales_invoices AS (
    SELECT
      `tabSales Invoice`.name,
      `tabSales Invoice`.posting_date,
      WEEK(`tabSales Invoice`.posting_date, 0) AS week_no,
      `tabSales Invoice`.customer,
      `tabSales Invoice`.customer_name,
      `tabSales Invoice`.base_grand_total,
      `tabSales Invoice`.status
    FROM
      `tabSales Invoice`
    WHERE
      `tabSales Invoice`.docstatus = 1
      AND {{ date }}
  )
SELECT
  posting_date,
  SUM(base_grand_total) AS TOTAL_DAILY_SALES
FROM
  sales_invoices
GROUP BY
  posting_date
ORDER BY
  posting_date ASC


-- Get the sales revenue contribution by customer
WITH customer_sales AS (
    SELECT 
        customer,
        customer_name,
        SUM(base_grand_total) AS total_sales_per 
        FROM `tabSales Invoice` 
        WHERE
            docstatus = 1
            AND is_opening = 0
            AND status NOT IN ('Return')
            AND posting_date BETWEEN '2026-07-01' AND '2026-07-31'
        GROUP BY customer, customer_name
 )
 SELECT
    customer, 
    customer_name,
    total_sales_per,
    SUM(total_sales_per) OVER () AS total_sales_revenue,
    (total_sales_per/SUM(total_sales_per) OVER ()) * 100 AS percentage  
FROM customer_sales 
    ORDER BY total_sales_per DESC


-- Weekly sales revenue
WITH
  sales_invoices AS (
    SELECT
      `tabSales Invoice`.name,
      `tabSales Invoice`.posting_date,
      WEEK(`tabSales Invoice`.posting_date, 0) AS week_no,
      `tabSales Invoice`.customer,
      `tabSales Invoice`.customer_name,
      `tabSales Invoice`.base_grand_total,
      `tabSales Invoice`.status
    FROM
      `tabSales Invoice`
    WHERE
      `tabSales Invoice`.docstatus = 1
      AND {{ date }}
  )
SELECT
  week_no,
  SUM(base_grand_total) AS total_weekly_sales
FROM
  sales_invoices
GROUP BY
  week_no


-- Individual sales report (Item wise sales report)
WITH
  sales_per_item AS (
    SELECT
      `tabSales Invoice`.name AS sales_invoice_id,
      sii.delivery_note AS delivery_note_id,
      `tabSales Invoice`.customer AS customer_code,
      `tabSales Invoice`.customer_name,
      st.sales_person AS sales_person_name,
      `tabSales Invoice`.posting_date,
      `tabSales Invoice`.due_date,
      `tabSales Invoice`.export_series,
      `tabSales Invoice`.etr_invoice_number,
      `tabSales Invoice`.tax_category,
      `tabSales Invoice`.status,
      `tabSales Invoice`.tax_id,
      `tabSales Invoice`.base_grand_total,
      CASE 
          WHEN dn.company_vehicle IS NOT NULL AND dn.company_vehicle !='' THEN dn.company_vehicle 
          WHEN dn.customer_provided_vehicle IS NOT NULL AND dn.customer_provided_vehicle !='' THEN dn.customer_provided_vehicle
          WHEN dn.transporter_vehicle_number IS NOT NULL AND dn.transporter_vehicle_number !='' THEN dn.transporter_vehicle_number
      ELSE NULL END AS vehicle_number,
      sii.item_code,
      sii.item_name,
      sii.qty AS Quantity_in_UOM,
      sii.base_rate,
      sii.base_amount,
      CASE
        WHEN `tabSales Invoice`.base_total_taxes_and_charges != 0 THEN `tabSales Invoice`.base_total_taxes_and_charges / `tabSales Invoice`.total_qty
        ELSE 0
      END AS tax_per_item,
      sii.tonnes_input AS Qty_in_Tonnes
    FROM
      `tabSales Invoice Item` AS sii
      LEFT JOIN `tabSales Invoice` ON sii.parent = `tabSales Invoice`.name
      LEFT JOIN `tabDelivery Note` AS dn ON sii.delivery_note = dn.name
      LEFT JOIN `tabCustomer` AS cu ON `tabSales Invoice`.customer = cu.name
      LEFT JOIN `tabSales Team` AS st ON `tabSales Invoice`.customer = st.parent
    WHERE
      `tabSales Invoice`.docstatus = 1
      AND `tabSales Invoice`.is_opening = 'No'
      AND {{ invoice_date }}
      AND {{ customer }}
    ORDER BY
      `tabSales Invoice`.name ASC,
      `tabSales Invoice`.posting_date ASC
  ),
  sales_with_tax AS (
    SELECT
      sales_invoice_id,
      delivery_note_id,
      customer_code,
      customer_name,
      sales_person_name,
      posting_date,
      due_date,
      vehicle_number,
      export_series,
      etr_invoice_number,
      tax_category,
      status,
      tax_id,
      item_code,
      item_name,
      Quantity_in_UOM,
      base_rate,
      base_amount,
      tax_per_item,
      (base_rate + tax_per_item) AS total_rate_with_tax,
      Qty_in_Tonnes,
      base_grand_total
    FROM
      sales_per_item
  )
SELECT
  sales_invoice_id,
  delivery_note_id,
  customer_code,
  customer_name,
  sales_person_name,
  posting_date,
  due_date,
  vehicle_number,
  export_series,
  etr_invoice_number,
  tax_category,
  status,
  tax_id,
  item_code,
  item_name,
  Quantity_in_UOM,
  Qty_in_Tonnes,
  base_rate AS rate_before_tax,
  base_amount AS amount_before_tax,
  tax_per_item,
  total_rate_with_tax AS rate_after_tax,
  (total_rate_with_tax * Quantity_in_UOM) AS amount_after_tax
FROM
  sales_with_tax
ORDER BY
  sales_invoice_id ASC