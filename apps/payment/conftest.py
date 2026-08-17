"""Ensure the service root is importable when pytest runs from apps/payment.

pytest's default prepend import mode adds the directory containing a
standalone conftest.py to sys.path, so the tests/ modules can do
`from payment_logic import ...` without relying on CWD being on the path.
"""
