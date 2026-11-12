import copy
import importlib.util
import json
import unittest
import auth
spec = importlib.util.spec_from_file_location('signup_health', auth.ROOT/'scripts/dev-signup-health.py')
health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(health)

class SignupReadinessTest(unittest.TestCase):
    def test_actual_registration_controls_required(self):
        realm = json.loads(auth.REALM.read_text())
        health.registration_ready(realm)
        for field, value in [('registrationAllowed',False),('verifyEmail',False),('smtpServer',{}),('realm','production')]:
            invalid = copy.deepcopy(realm)
            invalid[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                health.registration_ready(invalid)

if __name__ == '__main__':
    unittest.main()
