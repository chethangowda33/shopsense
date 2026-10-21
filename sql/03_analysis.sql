-- ShopSense: analysis queries
-- Run one query at a time: click inside it, then Ctrl+Enter.

USE shopsense;

-- Q1. Who are the biggest customers? (top 5 by purchases)
-- Check: CUST_027 = 143108.00, same as the Excel pivot
SELECT customer_id,
       SUM(amount) AS total_bought
FROM ledger
WHERE entry_type = 'Purchase'
GROUP BY customer_id
ORDER BY total_bought DESC
LIMIT 5;

-- Q2. Who has paid the most? (top 5 by payments)
-- Check: CUST_027 = 149888.00, same as Total_Paid in Excel Customer_Summary
SELECT customer_id,
       SUM(amount) AS total_paid
FROM ledger
WHERE entry_type = 'Payment'
GROUP BY customer_id
ORDER BY total_paid DESC
LIMIT 5;
