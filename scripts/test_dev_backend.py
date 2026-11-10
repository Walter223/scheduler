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


class PreflightTest(unittest.TestCase):
    def test_forbids_ci_remote_and_nondev_configuration(self):
        for env in [{'CI':'true'}, {'MIX_ENV':'test'}, {'MIX_ENV':'prod'}, {'DATABASE_URL':'postgres://remote/anything'}]:
            with self.assertRaises(ValueError):
                module.environment(env, Path('/unused-secret-file'))

    def test_migration_requires_exact_confirmation_and_development(self):
        from unittest.mock import patch
        with patch.object(module, 'preflight') as checked:
            for env, target in [({'MIX_ENV':'dev'},'other'), ({'MIX_ENV':'test'},'scheduler_api_dev'), ({'MIX_ENV':'dev','CI':'true'},'scheduler_api_dev')]:
                with self.assertRaises(ValueError): module.migrate(env,target)
            checked.assert_not_called()

    def test_pending_filter_excludes_formatter_and_rejects_unknown_applied_versions(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            migrations=root/'backend/priv/repo/migrations'
            migrations.mkdir(parents=True)
            (migrations/'.formatter.exs').write_text('[]')
            (migrations/'20261107021611_example.exs').write_text('')
            with patch.object(module,'ROOT',root):
                self.assertEqual(module.pending_versions({'versions':[]}),[20261107021611])
                self.assertEqual(module.pending_versions({'versions':[20261107021611]}),[])
                with self.assertRaises(ValueError):module.pending_versions({'versions':[1]})

    def test_verified_backup_is_required_before_migration_tool(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            env={'MIX_ENV':'dev'}
            with patch.object(module,'ROOT',Path(directory)), patch.object(module,'pending_versions',return_value=[1]), patch.object(module,'preflight',side_effect=[{'versions':[]},ValueError('backup failed')]), patch.object(module.subprocess,'run') as run:
                with self.assertRaises(ValueError):module.migrate(env,'scheduler_api_dev')
                run.assert_not_called()

    def test_check_reports_pending_without_writes_or_start(self):
        from unittest.mock import patch
        with patch.object(module.sys,'argv',['dev-backend.py','--check']), patch.object(module,'environment',return_value={'MIX_ENV':'dev'}), patch.object(module,'preflight',return_value={'versions':[]}), patch.object(module,'pending_versions',return_value=[20261107023947]), patch.object(module,'migrate') as migrate, patch.object(module.os,'execvpe') as start:
            with self.assertRaisesRegex(ValueError,'Pending development migrations'):
                module.main()
            migrate.assert_not_called()
            start.assert_not_called()

    def test_occupied_port_refuses_before_opt_in_migration(self):
        from unittest.mock import patch, MagicMock
        connection=MagicMock()
        with patch.object(module.sys,'argv',['dev-backend.py','--migrate','--confirm-database','scheduler_api_dev']), patch.object(module,'environment',return_value={'MIX_ENV':'dev'}), patch.object(module.socket,'create_connection',return_value=connection), patch.object(module,'migrate') as migrate:
            with self.assertRaisesRegex(ValueError,'occupied'):
                module.main()
            migrate.assert_not_called()

    def test_read_only_preflight_strips_inherited_write_flags(self):
        from unittest.mock import patch, Mock
        result=Mock(returncode=0,stdout='MAGNUM_DEV_PREFLIGHT {"versions": []}\n')
        with patch.object(module.subprocess,'run',return_value=result) as run:
            module.preflight({'MAGNUM_DEV_BACKUP':'unapproved','MAGNUM_DEV_BASELINE':'unapproved'})
            checked=run.call_args.kwargs['env']
            self.assertNotIn('MAGNUM_DEV_BACKUP',checked)
            self.assertNotIn('MAGNUM_DEV_BASELINE',checked)

if __name__ == '__main__':
    unittest.main()
