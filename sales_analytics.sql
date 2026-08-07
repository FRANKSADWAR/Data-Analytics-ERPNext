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


-- Daily sales target to be delivred with respect with the current sales orders
WITH
  -- General rules are: only orders from 7 days ago are selected
  -- Only items in orders whose delivery percentage is less than 60 percent are considered
  -- Transport item has been excluded
  -- Only approved sales orders have been considered
  -- If the quantity in tonnes is more than 17, we can only have one truck delieved
  -- If the customer is an export customer,  we will rise the limit to 28 Tonnes
  -- If the product has more than 340 bags to deliver and is a product with 25 bags packaging, we will consider the 560 or 480 quantity
  -- Add column for order date and difference between order date and curdate (Age)
  -- Add column for current stock balance in the warehouse
  
  sales_orders_to_deliver AS (
    SELECT
      `tabSales Order`.name AS sales_order_id,
      DATE(`tabSales Order`.creation) AS order_date,
      `tabSales Order`.delivery_date,
      `tabSales Order`.customer_name,
      `tabSales Order`.per_delivered,
      `tabSales Order`.per_billed,
      `tabSales Order`.status,
      `tabSales Team`.sales_person,
      `tabSales Order Item`.item_code,
      `tabSales Order Item`.item_name,
      `tabSales Order Item`.weight_per_unit,
      `tabSales Order Item`.delivered_qty,
      `tabSales Order`.currency,
      `tabSales Order`.conversion_rate,
      CASE
        WHEN `tabSales Order Item`.item_tax_template = 'Kenya Tax - NML' THEN ROUND(`tabSales Order Item`.rate * 1.16, 2)
        ELSE `tabSales Order Item`.rate
      END AS rate,
      `tabSales Order Item`.qty - `tabSales Order Item`.delivered_qty AS qty_to_deliver,
      `tabSales Order Item`.qty * `tabSales Order Item`.weight_per_unit AS weight_in_tonnes
    FROM
      `tabSales Order`
      LEFT JOIN `tabSales Team` ON `tabSales Order`.name = `tabSales Team`.parent
      LEFT JOIN `tabSales Order Item` ON `tabSales Order`.name = `tabSales Order Item`.parent
    WHERE
      `tabSales Order`.docstatus = 1
      AND `tabSales Order`.per_delivered <= 60
      AND DATE(`tabSales Order`.transaction_date) >= DATE_SUB(CURDATE(), INTERVAL 7 DAY)
      AND `tabSales Order`.status NOT IN('Closed', 'Completed', 'On Hold')
      AND `tabSales Order Item`.item_code <> 'SRV-001'
      AND (`tabSales Order Item`.qty - `tabSales Order Item`.delivered_qty) > 0
  ),
  sales_orders_transformed AS (
    SELECT
        customer_name,
        sales_order_id,
        order_date,
        delivery_date,
        sales_person,
        item_code,
        item_name,
        weight_per_unit,
        conversion_rate,
        CASE
            WHEN qty_to_deliver >= 680  AND weight_per_unit = 0.025 AND currency = 'KES' THEN  680
            WHEN qty_to_deliver >= 680 AND weight_per_unit = 0.025 AND currency = 'USD' THEN 680
            WHEN qty_to_deliver = 480 AND weight_per_unit = 0.025 THEN 480 
            WHEN qty_to_deliver >= 340 AND currency  = 'KES' THEN 340
            WHEN qty_to_deliver >= 560 AND currency ='USD' THEN 560
        ELSE qty_to_deliver END AS bags_to_deliver,
        
        CASE
            WHEN currency = 'USD' THEN rate * conversion_rate 
            ELSE rate END AS product_rate
    FROM sales_orders_to_deliver     
  ),
  conversion_table AS (
    SELECT
        customer_name,
        sales_order_id,
        order_date,
        delivery_date,
        sales_person,
        item_code,
        item_name,
        (weight_per_unit * bags_to_deliver) AS quantity_in_tonnes,
        (bags_to_deliver * product_rate) AS product_amount
    FROM
      sales_orders_transformed
  ),
  
  to_deliver_table AS (
    SELECT 
        customer_name, 
        item_code, 
        item_name, 
        sales_person,
        ROUND(SUM(quantity_in_tonnes),2) AS total_quantity_tonnes,
        SUM(product_amount) AS total_amount 
    FROM conversion_table 
    GROUP BY customer_name, item_code, item_name
  ),
  to_deliver_summary AS (
    SELECT 
        "Potential Deliveries" AS customer_name,
        "" AS item_code,
        "" AS item_name,
        "",
        ROUND(SUM(total_quantity_tonnes),2) AS total_quantity_tonnes,
        SUM(total_amount) AS total_amount
    FROM to_deliver_table
    
  ),
  sales_today AS (
    SELECT
        "Sales Today",
        "",
        "",
        "",
        "",
        SUM(`tabSales Invoice`.base_grand_total) AS sales_today
    FROM
        `tabSales Invoice`
        INNER JOIN `tabCompany` AS cmp ON `tabSales Invoice`.company = cmp.name
        INNER JOIN `tabCustomer` AS cu ON `tabSales Invoice`.customer = cu.name
    WHERE
        `tabSales Invoice`.docstatus = 1
        AND `tabSales Invoice`.posting_date = CURDATE()
  ),
  sales_target AS (
    SELECT
        "Sales Target",
        "",
        "",
        "",
        "",
        (135000000/31) AS daily_sales_target
  )
  
  SELECT * FROM to_deliver_table 
  UNION ALL 
  SELECT * FROM to_deliver_summary
  UNION ALL 
  SELECT * FROM sales_today
  UNION ALL
  SELECT * FROM sales_target 
  
  
WITH sales_invoices AS (
  SELECT
    `tabSales Invoice`.posting_date,
    `tabSales Invoice`.name AS sales_invoice_id,
    `tabSales Invoice`.customer,
    `tabSales Invoice`.customer_name,
    `tabSales Invoice`.base_grand_total,
    `tabSales Invoice`.status
  FROM `tabSales Invoice`
  WHERE
    `tabSales Invoice`.docstatus = 1
    AND `tabSales Invoice`.status NOT IN ('Return')
    AND MONTH(posting_date) = MONTH(CURDATE())
    AND YEAR(posting_date) = YEAR(posting_date)
)

SELECT 
  posting_date, 
  SUM(base_grand_total) AS daily_sales,
  SUM(base_grand_total) OVER(PARTITION BY posting_date) AS cumulative_sales
FROM sales_invoices 
GROUP BY posting_date 
ORDER BY posting_date ASC


   