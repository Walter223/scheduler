"""Pure launcher configuration tests; no real secrets or services."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
spec = importlib.util.spec_from_file_location('dev_backend', Path(__file__).with_name('dev-backend.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class EnvironmentTest(unittest.TestCase):
    def test_fixed_development_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / '.env'
            path.write_text('MAGNUM_WEB_CLIENT_SECRET=fictional-unit-test-value\n')
            env = module.environment({}, path)
            self.assertEqual(env['MIX_ENV'], 'dev')
            self.assertEqual(env['OIDC_REDIRECT_URI'], 'http://localhost:5173/auth/callback')
            self.assertEqual(env['MAGNUM_OIDC_ENABLED'], 'true')
            self.assertEqual(env['PORT'], '4000')
            with self.assertRaises(ValueError):
                module.environment({'MIX_ENV': 'prod'}, path)
            path.write_text('OTHER=value\n')
            with self.assertRaises(ValueError):
                module.environment({}, path)

if __name__ == '__main__':
    unittest.main()
