import unittest

import support  # noqa: F401
from tmc import validate


class ValidateTests(unittest.TestCase):
    def test_slugs(self) -> None:
        self.assertEqual(validate.slug("bluekite"), "bluekite")
        self.assertEqual(validate.slug("voice-2"), "voice-2")
        for bad in ["", "-lead", "Upper", "a" * 41, "a/b", "a b", "a;rm"]:
            with self.subTest(bad=bad), self.assertRaises(validate.ValidationError):
                validate.slug(bad)

    def test_users(self) -> None:
        self.assertEqual(validate.user("mattceran"), "mattceran")
        for bad in ["", "root", "Matt", "1matt", "a" * 33, "matt ceran", "matt$"]:
            with self.subTest(bad=bad), self.assertRaises(validate.ValidationError):
                validate.user(bad)

    def test_pane_identifiers_are_normalized(self) -> None:
        self.assertEqual(
            validate.pane_id("62627400-914E-41CE-9A05-9E624481653F"),
            "62627400-914e-41ce-9a05-9e624481653f",
        )
        with self.assertRaises(validate.ValidationError):
            validate.pane_id("62627400; rm -rf /")

    def test_paths_reject_traversal_and_control_characters(self) -> None:
        self.assertEqual(
            validate.absolute_path("/Users/mattceran/Documents/bluekite"),
            "/Users/mattceran/Documents/bluekite",
        )
        self.assertEqual(validate.absolute_path("/Users/m/My Project"), "/Users/m/My Project")
        for bad in ["", "relative", "/a/../b", "/a/./b", "/a//b", "/a\nb", "/a/$(x)", "/a/`x`"]:
            with self.subTest(bad=bad), self.assertRaises(validate.ValidationError):
                validate.absolute_path(bad)

    def test_home_paths_mirror_the_mac_home_folder(self) -> None:
        self.assertEqual(validate.home_path("/Users/mattceran"), "/Users/mattceran")
        self.assertEqual(validate.home_path("/home/sam"), "/home/sam")
        for bad in ["/Users", "/Users/a/b", "/etc/x", "/root"]:
            with self.subTest(bad=bad), self.assertRaises(validate.ValidationError):
                validate.home_path(bad)

    def test_public_keys(self) -> None:
        key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGq8 termuctive@mac"
        self.assertEqual(validate.public_key(key + "\n"), key)
        for bad in ["", "ssh-ed25519", "ssh-dss AAAA", key + "\nssh-ed25519 AAAA", 'x" ssh-ed25519']:
            with self.subTest(bad=bad), self.assertRaises(validate.ValidationError):
                validate.public_key(bad)

    def test_is_within(self) -> None:
        self.assertTrue(validate.is_within("/Users/m/project", "/Users/m"))
        self.assertTrue(validate.is_within("/Users/m", "/Users/m"))
        self.assertFalse(validate.is_within("/Users/mallory/x", "/Users/m"))


if __name__ == "__main__":
    unittest.main()
