import unittest

import support  # noqa: F401
from tmc import admin, paths, setup


class SetupTests(unittest.TestCase):
    def test_sshd_drop_in_only_disables_passwords_when_requested(self) -> None:
        with_passwords = setup.sshd_drop_in(disable_passwords=False)
        without_passwords = setup.sshd_drop_in(disable_passwords=True)
        self.assertIn("MaxSessions 32", with_passwords)
        self.assertIn("PermitRootLogin no", with_passwords)
        self.assertNotIn("PasswordAuthentication", with_passwords)
        self.assertIn("PasswordAuthentication no", without_passwords)

    def test_firewall_only_enables_when_the_current_connection_stays_allowed(self) -> None:
        networks = ["192.168.1.0/24"]
        self.assertTrue(setup.ssh_source_allowed("192.168.1.20", networks))
        self.assertTrue(setup.ssh_source_allowed("100.101.102.103", networks))
        self.assertTrue(setup.ssh_source_allowed(None, networks))
        self.assertFalse(setup.ssh_source_allowed("203.0.113.9", networks))
        self.assertFalse(setup.ssh_source_allowed("not-an-ip", networks))

    def test_member_sudoers_rule_only_allows_the_admin_subcommand(self) -> None:
        rule = admin.member_sudoers_rule("mattceran")
        self.assertEqual(
            rule, f"mattceran ALL=(root) NOPASSWD: {paths.stable_tmc()} admin *\n"
        )

    def test_packages_include_what_sessions_need(self) -> None:
        for package in ["tmux", "git", "rsync", "acl", "ncurses-term", "python3"]:
            self.assertIn(package, setup.BASE_PACKAGES)


if __name__ == "__main__":
    unittest.main()
