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


