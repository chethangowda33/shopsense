-- =====================================================================
-- ShopSense: full SQL analysis (MySQL 9.2, database: shopsense)
-- Tables: ledger (2,887 rows), customers (27 rows)
--
-- How to run: click inside ONE query, press Ctrl+Enter.
-- Every query has: the business question, what it does, and a CHECK
-- (the number you should see - it matches the Excel workbook).
-- =====================================================================

USE shopsense;


-- =====================================================================
-- A. DATA CHECKS  (can we trust the data before analysing it?)
-- =====================================================================

-- A1. How many rows of each type?
-- CHECK: Purchase 2585, Payment 194, Adjustment 83, Old_Balance 25
SELECT entry_type,
       COUNT(*) AS rows_count
FROM ledger
GROUP BY entry_type
ORDER BY rows_count DESC;

-- A2. Blank dates, unclear rows, and the date range of the book
-- COUNT(*) counts all rows; COUNT(entry_date) skips NULLs, so the difference = blank dates.
-- CHECK: blank_dates 109, check_rows 23, first 2021-11-20, last 2025-04-12
SELECT COUNT(*) - COUNT(entry_date)          AS blank_dates,
       SUM(notes LIKE 'CHECK:%')             AS check_rows,
       MIN(entry_date)                       AS first_date,
       MAX(entry_date)                       AS last_date
FROM ledger;

-- A3. Any ledger customer missing from the customers table?
-- LEFT JOIN keeps every ledger row; if no customer matches, c.customer_id is NULL.
-- CHECK: 0 rows returned
SELECT DISTINCT l.customer_id
FROM ledger l
LEFT JOIN customers c ON l.customer_id = c.customer_id
WHERE c.customer_id IS NULL;


-- =====================================================================
-- B. Q1 - WHO ARE THE BIGGEST CUSTOMERS? (concentration risk)
-- =====================================================================

-- B1. Purchases per customer, their % of all purchases, and their rank
-- SUM(SUM(amount)) OVER () = grand total across all customers (a "window function"),
-- so each row can be divided by it - same as the pivot's "% of Grand Total".
-- CHECK: CUST_027 143108.00, 20.89 %, rank 1
SELECT customer_id,
       SUM(amount)                                            AS total_bought,
       ROUND(100 * SUM(amount) / SUM(SUM(amount)) OVER (), 2) AS pct_of_sales,
       RANK() OVER (ORDER BY SUM(amount) DESC)                AS sales_rank
FROM ledger
WHERE entry_type = 'Purchase'
GROUP BY customer_id
ORDER BY total_bought DESC;

-- B2. What share of sales comes from the top 5 customers?
-- WITH ... AS ( ) = a CTE: a named temporary result you can query again.
-- CHECK: top5_pct 47.92
WITH sales AS (
    SELECT customer_id,
           SUM(amount) AS total_bought
    FROM ledger
    WHERE entry_type = 'Purchase'
    GROUP BY customer_id
),
top5 AS (
    SELECT total_bought
    FROM sales
    ORDER BY total_bought DESC
    LIMIT 5
)
SELECT ROUND(100 * (SELECT SUM(total_bought) FROM top5)
                 / (SELECT SUM(total_bought) FROM sales), 2) AS top5_pct;


-- =====================================================================
-- C. Q2 - WHO OWES THE MOST RIGHT NOW?
-- Balance = Old_Balance + Purchase + Adjustment - Payment
-- =====================================================================

-- C1. Balance of every customer in one query
-- CASE WHEN = Excel IF: payments become minus, everything else stays plus.
-- CHECK: CUST_013 16273, CUST_019 13007, CUST_001 10301 (matches dad's book)
SELECT customer_id,
       SUM(CASE WHEN entry_type = 'Payment' THEN -amount ELSE amount END) AS owes_now
FROM ledger
GROUP BY customer_id
ORDER BY owes_now DESC;

-- C2. Total money the shop is waiting to collect
-- CHECK: 115826.00
SELECT SUM(CASE WHEN entry_type = 'Payment' THEN -amount ELSE amount END) AS total_owed
FROM ledger;


-- =====================================================================
-- D. Q3 - WHO PAYS IN FULL vs WHO KEEPS A BALANCE?
-- =====================================================================

-- D1. % of everything billed that has been paid, with a risk flag
-- billed = Old_Balance + Purchase + Adjustment (not just purchases, because some
-- customers were also clearing old dues). NULLIF avoids dividing by zero.
-- CHECK: 7 customers flagged 'Below 70%': CUST_001, 005, 009, 012, 013, 022, 025
SELECT customer_id,
       SUM(CASE WHEN entry_type <> 'Payment' THEN amount ELSE 0 END) AS billed,
       SUM(CASE WHEN entry_type =  'Payment' THEN amount ELSE 0 END) AS paid,
       ROUND(100 * SUM(CASE WHEN entry_type = 'Payment' THEN amount ELSE 0 END)
                 / NULLIF(SUM(CASE WHEN entry_type <> 'Payment' THEN amount ELSE 0 END), 0), 1) AS pct_paid,
       CASE WHEN SUM(CASE WHEN entry_type = 'Payment' THEN amount ELSE 0 END)
                 < 0.7 * SUM(CASE WHEN entry_type <> 'Payment' THEN amount ELSE 0 END)
            THEN 'Below 70%' ELSE 'OK' END AS risk_flag
FROM ledger
GROUP BY customer_id
ORDER BY pct_paid;

-- D2. Does dad's label match reality? (JOIN ledger with customers)
-- JOIN ... ON = Excel XLOOKUP: bring pays_type from customers using customer_id.
-- CHECK: CUST_007 (9084), CUST_015 (4109), CUST_018 (3172) are 'Pays full' but owe money
WITH balances AS (
    SELECT customer_id,
           SUM(CASE WHEN entry_type = 'Payment' THEN -amount ELSE amount END) AS owes_now
    FROM ledger
    GROUP BY customer_id
)
SELECT b.customer_id,
       c.pays_type,
       b.owes_now
FROM balances b
JOIN customers c ON b.customer_id = c.customer_id
WHERE c.pays_type = 'Pays full'
  AND b.owes_now > 1000
ORDER BY b.owes_now DESC;

-- D3. Summary by dad's label
-- CHECK: Carries forward 15 customers, owe 75098, avg 69.4 % paid
--        Mixed            7 customers, owe 24363, avg 92.6 % paid
--        Pays full        5 customers, owe 16365, avg 89.6 % paid
WITH per_customer AS (
    SELECT customer_id,
           SUM(CASE WHEN entry_type = 'Payment' THEN -amount ELSE amount END) AS owes_now,
           100 * SUM(CASE WHEN entry_type = 'Payment' THEN amount ELSE 0 END)
               / NULLIF(SUM(CASE WHEN entry_type <> 'Payment' THEN amount ELSE 0 END), 0) AS pct_paid
    FROM ledger
    GROUP BY customer_id
)
SELECT c.pays_type,
       COUNT(*)                AS customers,
       SUM(p.owes_now)         AS total_owed,
       ROUND(AVG(p.pct_paid), 1) AS avg_pct_paid
FROM per_customer p
JOIN customers c ON p.customer_id = c.customer_id
GROUP BY c.pays_type
ORDER BY total_owed DESC;


-- =====================================================================
-- E. Q4 - WHO IS BUYING LESS / PAYING LESS? (early warning)
-- Note: different customers' pages cover different years, so compare a
-- customer with their OWN history, not with the end of the whole book.
-- =====================================================================

-- E1. First entry, last purchase and last payment of each customer
-- MAX(CASE WHEN ... THEN entry_date END) = latest date of only that type.
-- CHECK: CUST_001 last purchase 2025-03-27, last payment 2025-02-03
--        CUST_009 last_payment NULL (never paid)
SELECT customer_id,
       MIN(entry_date)                                                AS first_date,
       MAX(CASE WHEN entry_type = 'Purchase' THEN entry_date END)     AS last_purchase,
       MAX(CASE WHEN entry_type = 'Payment'  THEN entry_date END)     AS last_payment,
       SUM(entry_type = 'Purchase')                                   AS purchases
FROM ledger
GROUP BY customer_id
ORDER BY last_purchase DESC;

-- E2. Monthly purchases and visits of every customer (feeds the Power BI line chart)
-- CHECK: CUST_001 2025-01 = 23 visits, 4702.00
SELECT customer_id,
       DATE_FORMAT(entry_date, '%Y-%m') AS month,
       COUNT(*)                         AS visits,
       SUM(amount)                      AS total_bought
FROM ledger
WHERE entry_type = 'Purchase'
GROUP BY customer_id, month
ORDER BY customer_id, month;

-- E3. CUST_001 month-over-month change
-- LAG(x) OVER (ORDER BY month) = the value from the previous row (previous month).
-- CHECK: 2024-12 +3882, 2025-01 +518, 2025-02 -1535, 2025-03 -1546 (falling), April missing = 0
WITH monthly AS (
    SELECT DATE_FORMAT(entry_date, '%Y-%m') AS month,
           SUM(amount)                      AS total_bought
    FROM ledger
    WHERE customer_id = 'CUST_001'
      AND entry_type = 'Purchase'
    GROUP BY month
)
SELECT month,
       total_bought,
       total_bought - LAG(total_bought) OVER (ORDER BY month) AS change_vs_last_month
FROM monthly
ORDER BY month;

-- E4. Whole-shop credit sales per month
-- CHECK: 31 months returned; best month 2022-10 = 85015.00
-- (months are missing where no photographed page covers that period)
SELECT DATE_FORMAT(entry_date, '%Y-%m') AS month,
       COUNT(DISTINCT customer_id)      AS active_customers,
       SUM(amount)                      AS total_bought
FROM ledger
WHERE entry_type = 'Purchase'
GROUP BY month
ORDER BY month;


-- =====================================================================
-- F. A VIEW FOR POWER BI  (one row per customer, like Excel Customer_Summary)
-- A VIEW = a saved query that behaves like a table. Power BI can read it directly.
-- =====================================================================

-- F1. Create (or update) the view
CREATE OR REPLACE VIEW customer_summary AS
SELECT l.customer_id,
       c.pays_type,
       SUM(CASE WHEN l.entry_type = 'Purchase'    THEN l.amount ELSE 0 END) AS total_bought,
       SUM(CASE WHEN l.entry_type = 'Payment'     THEN l.amount ELSE 0 END) AS total_paid,
       SUM(CASE WHEN l.entry_type = 'Old_Balance' THEN l.amount ELSE 0 END) AS old_balance,
       SUM(CASE WHEN l.entry_type = 'Adjustment'  THEN l.amount ELSE 0 END) AS adjustments,
       SUM(CASE WHEN l.entry_type = 'Payment' THEN -l.amount ELSE l.amount END) AS owes_now,
       ROUND(100 * SUM(CASE WHEN l.entry_type = 'Payment' THEN l.amount ELSE 0 END)
                 / NULLIF(SUM(CASE WHEN l.entry_type <> 'Payment' THEN l.amount ELSE 0 END), 0), 1) AS pct_paid,
       SUM(l.entry_type = 'Purchase')                                       AS purchases,
       MAX(CASE WHEN l.entry_type = 'Purchase' THEN l.entry_date END)       AS last_purchase
FROM ledger l
JOIN customers c ON l.customer_id = c.customer_id
GROUP BY l.customer_id, c.pays_type;

-- F2. Use the view like a table
-- CHECK: 27 rows; first row CUST_013, owes_now 16273.00, pct_paid 55.1
SELECT *
FROM customer_summary
ORDER BY owes_now DESC;
SELECT *
FROM customers;
