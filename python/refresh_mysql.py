"""
ShopSense: reload MySQL from the Excel workbook.

Copies the Ledger sheet and the Customers sheet (WITHOUT real names) from
ShopSense_Ledger.xlsx into the MySQL tables shopsense.ledger and shopsense.customers.
The view customer_summary updates by itself.

Run:   py -3.12 refresh_mysql.py            (asks for the MySQL password)
       py -3.12 refresh_mysql.py --dry-run  (only checks the Excel data, no MySQL)

Always SAVE the Excel file first - this script reads the saved file.
"""
import sys
from getpass import getpass
from pathlib import Path

import pandas as pd
import pymysql

HERE = Path(__file__).resolve().parent
WORKBOOK = HERE.parent / "ShopSense_Ledger.xlsx"
VALID_TYPES = {"Purchase", "Payment", "Old_Balance", "Adjustment"}


def clean(v):
    """Turn pandas blanks (NaN / NaT) into None so MySQL stores NULL."""
    if v is None or pd.isna(v):
        return None
    if isinstance(v, pd.Timestamp):
        return v.date()
    if isinstance(v, float) and v.is_integer():
        return int(v)
    return v


def read_excel():
    # Ledger: A Date, B Customer_ID, C Type, D Amount, E Written_Balance, F Page_No, G Notes
    ledger = pd.read_excel(WORKBOOK, sheet_name="Ledger", usecols="A:G")
    ledger.columns = ["entry_date", "customer_id", "entry_type", "amount",
                      "written_balance", "page_no", "notes"]
    ledger = ledger.dropna(how="all")                      # ignore fully empty rows at the bottom
    ledger["entry_date"] = pd.to_datetime(ledger["entry_date"], errors="coerce")
    ledger.insert(0, "entry_id", range(1, len(ledger) + 1))

    # Customers: A Customer_ID, D Pays type, F Account_No, E Notes.  Column B (real name) is never read.
    customers = pd.read_excel(WORKBOOK, sheet_name="Customers", usecols="A,D,E,F")
    customers.columns = ["customer_id", "pays_type", "notes", "account_no"]
    customers = customers.dropna(subset=["customer_id"])
    customers["account_no"] = customers["account_no"].map(
        lambda v: None if pd.isna(v) else str(int(v)) if isinstance(v, float) else str(v))
    return ledger, customers


def check(ledger, customers):
    """Stop before touching MySQL if the Excel data has obvious mistakes."""
    problems = []
    if ledger["customer_id"].isna().any():
        problems.append(f"{ledger['customer_id'].isna().sum()} ledger rows have no Customer_ID")
    bad_types = sorted(set(ledger["entry_type"].dropna()) - VALID_TYPES)
    if bad_types or ledger["entry_type"].isna().any():
        problems.append(f"Type must be one of {sorted(VALID_TYPES)}; found {bad_types or 'blanks'}")
    amounts = pd.to_numeric(ledger["amount"], errors="coerce")
    if amounts.isna().any():
        rows = (ledger.index[amounts.isna()] + 2).tolist()[:10]
        problems.append(f"Amount is blank or not a number on Excel rows {rows}")
    unknown = sorted(set(ledger["customer_id"].dropna()) - set(customers["customer_id"]))
    if unknown:
        problems.append(f"Customer IDs missing from the Customers sheet: {unknown}")
    if customers["customer_id"].duplicated().any():
        problems.append("Customers sheet has a duplicate Customer_ID")
    return problems


def summary(ledger, customers):
    print(f"  customers:    {len(customers)}")
    print(f"  ledger rows:  {len(ledger)}  ({ledger['entry_date'].isna().sum()} without a date)")
    print(f"  date range:   {ledger['entry_date'].min():%d-%m-%Y} to {ledger['entry_date'].max():%d-%m-%Y}")
    signed = ledger["amount"].where(ledger["entry_type"] != "Payment", -ledger["amount"])
    print(f"  purchases:    Rs {ledger.loc[ledger['entry_type'] == 'Purchase', 'amount'].sum():,.0f}")
    print(f"  total owed:   Rs {signed.sum():,.0f}")


def load(ledger, customers, password):
    conn = pymysql.connect(host="localhost", user="root", password=password,
                           database="shopsense", autocommit=False)
    try:
        with conn.cursor() as cur:
            # DELETE (not TRUNCATE) so everything can be rolled back if an insert fails
            cur.execute("DELETE FROM ledger")
            cur.execute("DELETE FROM customers")
            cur.executemany(
                "INSERT INTO customers (customer_id, pays_type, account_no, notes) VALUES (%s, %s, %s, %s)",
                [tuple(clean(v) for v in r) for r in
                 customers[["customer_id", "pays_type", "account_no", "notes"]].itertuples(index=False)])
            cur.executemany(
                "INSERT INTO ledger (entry_id, entry_date, customer_id, entry_type, amount,"
                " written_balance, page_no, notes) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)",
                [tuple(clean(v) for v in r) for r in ledger.itertuples(index=False)])
            conn.commit()
            cur.execute("SELECT (SELECT COUNT(*) FROM customers), (SELECT COUNT(*) FROM ledger),"
                        " (SELECT SUM(owes_now) FROM customer_summary)")
            n_cust, n_rows, owed = cur.fetchone()
        print(f"\nMySQL now has {n_cust} customers and {n_rows} ledger rows; total owed Rs {owed:,.0f}")
    except Exception:
        conn.rollback()
        print("\nSomething went wrong - MySQL was left exactly as it was before.")
        raise
    finally:
        conn.close()


def main():
    print(f"Reading {WORKBOOK.name} (last saved version)...")
    if (WORKBOOK.parent / ("~$" + WORKBOOK.name)).exists():
        print("  Note: the workbook is open in Excel. Make sure you pressed Ctrl+S first.")
    ledger, customers = read_excel()
    summary(ledger, customers)

    problems = check(ledger, customers)
    if problems:
        print("\nFix these in Excel, save, and run again (MySQL was NOT changed):")
        for p in problems:
            print("  -", p)
        sys.exit(1)
    print("  checks:       OK")

    if "--dry-run" in sys.argv:
        print("\nDry run only - MySQL was not changed.")
        return
    load(ledger, customers, getpass("\nMySQL root password: "))
    print("Done. Next: Power BI -> Refresh, and Python notebook -> Run All.")


if __name__ == "__main__":
    main()
