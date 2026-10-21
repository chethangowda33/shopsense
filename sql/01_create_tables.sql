-- ShopSense: create the database and tables (MySQL 9.2)

CREATE DATABASE IF NOT EXISTS shopsense;
USE shopsense;

CREATE TABLE customers (
    customer_id  VARCHAR(10) PRIMARY KEY,
    pays_type    VARCHAR(20),
    account_no   VARCHAR(30),
    notes        VARCHAR(255)
);

CREATE TABLE ledger (
    entry_id         INT PRIMARY KEY,
    entry_date       DATE,
    customer_id      VARCHAR(10),
    entry_type       VARCHAR(20),
    amount           DECIMAL(10,2),
    written_balance  DECIMAL(10,2),
    page_no          INT,
    notes            VARCHAR(255)
);
