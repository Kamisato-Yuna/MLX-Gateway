import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("service_manager", Path(__file__).parents[1] / "script/service_manager.py")
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)
sys.path.insert(0, str(Path(__file__).parents[1] / "script"))


class ServiceManagerTests(unittest.TestCase):
    def test_configuration_preserves_endpoints_and_arguments(self):
        contents = {label: service.plist(label, ["/original/python", "--host", "127.0.0.1"], "/original/runtime", "test")
                    for label in service.LABELS}
        with tempfile.TemporaryDirectory() as directory, patch.object(service, "AGENTS", Path(directory)), patch.object(service, "call"):
            service.configure_jobs(contents, False, False)
            for label, original in contents.items():
                actual = plistlib.loads((Path(directory) / f"{label}.plist").read_bytes())
                expected = dict(original, RunAtLoad=False, KeepAlive=False)
                self.assertEqual(actual, expected)
                self.assertEqual(original["KeepAlive"], True)

    def test_recovery_requires_login_before_writes(self):
        with patch.object(service, "call") as command:
            with self.assertRaises(ValueError):
                service.configure_jobs({}, False, True)
            command.assert_not_called()

    def test_job_parser_ignores_nested_state(self):
        output = "\tstate = running\n\tpid = 42\n\truns = 3\n\tlast exit code = 0\n\tother = {\n\t\tstate = active\n\t}\n"
        with tempfile.TemporaryDirectory() as directory, patch.object(service, "AGENTS", Path(directory)), patch.object(service, "call", return_value=subprocess.CompletedProcess([], 0, output)):
            result = service.read_job(service.GATEWAY, False)
            self.assertEqual(result["state"], "running")
            self.assertEqual(result["pid"], 42)
            self.assertFalse(result["installed"])

    def test_manual_start_with_login_disabled_keeps_disabled_policy(self):
        with patch.object(service, "call", return_value=subprocess.CompletedProcess([], 1, "")) as command:
            service.start_configured_jobs({service.GATEWAY: {"RunAtLoad": False}})
            calls = [call.args[1:3] for call in command.call_args_list]
            self.assertEqual(calls, [("enable", service.job(service.GATEWAY)), ("print", service.job(service.GATEWAY)),
                                     ("bootstrap", service.DOMAIN), ("kickstart", service.job(service.GATEWAY)),
                                     ("disable", service.job(service.GATEWAY))])

    def test_stop_affects_only_managed_jobs_and_gateway_first(self):
        results = [subprocess.CompletedProcess([], code, "") for code in (0, 0, 0, 1, 0, 0, 1)]
        with patch.object(service, "call", side_effect=results) as command:
            service.stop_jobs()
            boots = [call.args[2] for call in command.call_args_list if call.args[1] == "bootout"]
            self.assertEqual(boots, [service.job(service.GATEWAY), service.job(service.WHISPER)])

    def test_unknown_control_process_is_not_terminated(self):
        with patch.object(service, "call", return_value=subprocess.CompletedProcess([], 0, "/other/app --service-control")), patch.object(service.os, "kill") as kill:
            with self.assertRaises(RuntimeError):
                service.stop_control_window(123)
            kill.assert_not_called()

    def test_maintenance_is_explicitly_one_shot(self):
        args = SimpleNamespace(operation="restart", login="true", recovery="true", control_pid=0)
        with tempfile.TemporaryDirectory() as directory, patch.object(service, "SUPPORT", Path(directory)), patch.object(service, "LOGS", Path(directory)), patch.object(service, "write_operation"), patch.object(service, "call", return_value=subprocess.CompletedProcess([], 1, "")) as command:
            service.submit(args)
            content = plistlib.loads((Path(directory) / "maintenance.plist").read_bytes())
            self.assertTrue(content["RunAtLoad"])
            self.assertFalse(content["KeepAlive"])
            self.assertEqual(content["ProgramArguments"][-2:], ["--control-pid", "0"])
            self.assertEqual(command.call_args.args[1], "bootstrap")

    def test_settings_reject_model_list_from_old_supervisor_child(self):
        jobs = [{"label": service.WHISPER, "loaded": True, "state": "running", "pid": 123}]
        config = {"baseURL": "http://127.0.0.1:44120/v1", "model": "whisper-1"}
        with patch("whisper_supervisor.listener_is_child", return_value=False), patch.object(service, "http_json") as request:
            self.assertFalse(service.whisper_ready(config, jobs))
            request.assert_not_called()

    def test_settings_reject_listener_change_during_http_probe(self):
        jobs = [{"label": service.WHISPER, "loaded": True, "state": "running", "pid": 123}]
        config = {"baseURL": "http://127.0.0.1:44120/v1", "model": "whisper-1"}
        with patch("whisper_supervisor.listener_is_child", side_effect=[True, False]), patch.object(service, "http_json", return_value={"data": [{"id": "whisper-1"}]}):
            self.assertFalse(service.whisper_ready(config, jobs))

    def test_existing_unmanaged_service_still_reports_actual_model(self):
        config = {"baseURL": "http://127.0.0.1:44120/v1", "model": "whisper-1"}
        with patch.object(service, "http_json", return_value={"data": [{"id": "whisper-1"}]}):
            self.assertTrue(service.whisper_ready(config, []))


if __name__ == "__main__":
    unittest.main()
