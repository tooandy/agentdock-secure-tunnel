from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ExternalModeStaticTests(unittest.TestCase):
    def test_windows_external_mode_reuses_dpapi_token(self):
        text = (ROOT / "scripts/windows.ps1").read_text(encoding="utf-8")
        self.assertIn("Add-Type -AssemblyName System.Security", text)
        self.assertIn("auth-token.dpapi", text)
        self.assertIn("agentdock.startup.v1", text)
        self.assertIn("DataProtectionScope]::CurrentUser", text)
        self.assertIn("deployment_mode must be auto, docker, native or external", text)
        self.assertIn("Test-AgentDockBearerAuth", text)
        self.assertNotIn("Set-Content $TokenPath $token", text)

    def test_windows_service_uses_named_scheduled_task(self):
        text = (ROOT / "scripts/windows-tunnel-service.ps1").read_text(encoding="utf-8")
        self.assertIn("$TaskName = 'AgentDock Secure Tunnel'", text)
        self.assertIn("$TaskPath = '\\AgentDock\\'", text)
        self.assertIn("New-ScheduledTaskTrigger -AtLogOn", text)
        self.assertIn("Register-ScheduledTask", text)
        self.assertIn("RestartCount 999", text)

    def test_entry_exposes_cross_platform_service_commands(self):
        text = (ROOT / "scripts/windows-entry.ps1").read_text(encoding="utf-8")
        for command in (
            "service-install",
            "service-start",
            "service-stop",
            "service-restart",
            "service-status",
            "service-uninstall",
        ):
            self.assertIn(command, text)
        self.assertIn("tunnel-run", text)

    def test_github_api_calls_support_a_token(self):
        # Unauthenticated api.github.com calls are capped at 60/hour per IP, which
        # stalls bootstrap on shared networks. Both PowerShell download paths must
        # forward GH_TOKEN/GITHUB_TOKEN to lift the limit.
        windows = (ROOT / "scripts/windows.ps1").read_text(encoding="utf-8")
        for marker in (
            "$env:GH_TOKEN",
            "$env:GITHUB_TOKEN",
            "api.github.com/repos/$Repo/releases/latest",
        ):
            self.assertIn(marker, windows)

        bootstrap = (ROOT / "scripts/bootstrap-tunnel.ps1").read_text(encoding="utf-8")
        self.assertIn("$env:GH_TOKEN", bootstrap)
        self.assertIn("$env:GITHUB_TOKEN", bootstrap)
        self.assertIn("api.github.com/repos/openai/tunnel-client/releases/latest", bootstrap)

    def test_example_documents_windows_runtime_override(self):
        text = (ROOT / "config.example.yaml").read_text(encoding="utf-8")
        self.assertIn("external_agentdock_runtime_root", text)
        self.assertIn("auth-token.dpapi", text)


if __name__ == "__main__":
    unittest.main()
