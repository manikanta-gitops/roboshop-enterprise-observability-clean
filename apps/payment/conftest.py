"""Ensure the service root is importable when pytest runs from apps/payment.

pytest's default prepend import mode only adds the basedir of each test
module (apps/payment/tests, which has no __init__.py) to sys.path, NOT the
service root. Without the service root on the path, tests that do
`from payment_logic import ...` fail with ModuleNotFoundError. Add it
explicitly so the fix does not depend on pytest's implicit conftest
path-insertion behavior.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
