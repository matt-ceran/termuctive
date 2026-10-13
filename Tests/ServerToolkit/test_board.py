import json
import os
import subprocess
import sys
import time
import unittest
import uuid

import support
from tmc import board, jsonio, paths, proc, sessionstate, tmuxctl, validate

TMC = str(support.TOOLKIT / "bin" / "tmc")


class BoardTestCase(support.TemporaryServerRoot):
    """Two members, both played by the current account, sharing one project."""

    def setUp(self) -> None:
        super().setUp()
        self.slug = "demo"
        self.me = proc.caller()
        self.partner = "sam" if self.me != "sam" else "matt"
        jsonio.write_json_atomic(
            paths.project_file(self.slug),
            {"slug": self.slug, "root": "/x", "owner": self.me, "members": [self.me, self.partner]},
        )
        for member in (self.me, self.partner):
            paths.member_dir(self.slug, member).mkdir(parents=True, exist_ok=True)
        paths.run_dir(self.slug).mkdir(parents=True, exist_ok=True)


class BoardTests(BoardTestCase):
    def test_tasks_flow_from_post_to_result(self) -> None:
        task = board.post(self.slug, self.me, self.partner, "Fix the login bug", "Details here")
        self.assertEqual([t["id"] for t in board.inbox(self.slug, self.partner)], [task["id"]])
        self.assertEqual(board.inbox(self.slug, self.me), [])

        board.decide(self.slug, self.partner, task["id"], "delivered", pane=str(uuid.uuid4()))
        self.assertEqual(board.inbox(self.slug, self.partner), [])
        board.decide(self.slug, self.partner, task["id"], "completed", result="Fixed in abc123")

        finished = board.finished_for_author(self.slug, self.me)
        self.assertEqual([t["result"] for t in finished], ["Fixed in abc123"])
        board.decide(self.slug, self.me, task["id"], "result-delivered")
        self.assertEqual(board.finished_for_author(self.slug, self.me), [])

    def test_authorship_comes_from_the_file_owner(self) -> None:
        board.append(
            self.slug,
            self.partner,
            "outbox.jsonl",
            {"id": "tforged", "from": self.me, "to": self.me, "kind": "task", "title": "x", "createdAt": 1},
        )
        task = next(t for t in board.tasks(self.slug) if t["id"] == "tforged")
        self.assertEqual(task["from"], self.partner)

        mine = board.post(self.slug, self.me, self.partner, "Only the recipient decides")
        board.decide(self.slug, self.me, mine["id"], "completed", result="forged")
        status = next(t for t in board.tasks(self.slug) if t["id"] == mine["id"])["status"]
        self.assertEqual(status, "proposed")

    def test_strangers_and_unknown_recipients_are_refused(self) -> None:
        with self.assertRaises(validate.ValidationError):
            board.post(self.slug, "mallory", self.me, "hi")
        with self.assertRaises(validate.ValidationError):
            board.post(self.slug, self.me, "mallory", "hi")

    def test_paused_auto_run_leaves_tasks_proposed(self) -> None:
        board.set_auto_run(self.slug, self.partner, False)
        task = board.post(self.slug, self.me, self.partner, "Wait for me")
        report = board.dispatch_once(self.slug, self.partner)
        self.assertEqual(report["delivered"] + report["queued"], [])
        self.assertIsNone(board.next_for_stop_hook(self.slug, self.partner, str(uuid.uuid4())))
        self.assertEqual(board.inbox(self.slug, self.partner)[0]["id"], task["id"])

    def test_stop_hook_hands_over_queued_work_then_results(self) -> None:
        pane = str(uuid.uuid4())
        task = board.post(self.slug, self.me, self.partner, "Write tests", from_pane=pane)
        text = board.next_for_stop_hook(self.slug, self.partner, str(uuid.uuid4()))
        self.assertIn(f"[Task {task['id']} from {self.me}'s agent] Write tests", text)
        self.assertIn("update_task", text)
        self.assertIsNone(board.next_for_stop_hook(self.slug, self.partner, str(uuid.uuid4())))

        board.decide(self.slug, self.partner, task["id"], "completed", result="12 tests added")
        result = board.next_for_stop_hook(self.slug, self.me, pane)
        self.assertIn("finished by", result)
        self.assertIn("12 tests added", result)


@support.requires_tmux
class DispatchTests(BoardTestCase):
    def tearDown(self) -> None:
        for member in (self.me, self.partner):
            subprocess.run(
                tmuxctl.tmux_command(self.slug, member, "kill-server"),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        super().tearDown()

    def idle_session(self, member: str) -> str:
        pane = str(uuid.uuid4())
        subprocess.run(
            tmuxctl.tmux_command(self.slug, member, "new-session", "-d", "-s", "tmc-" + pane, "cat"),
            check=True,
        )
        sessionstate.update(self.slug, member, pane, {"claude": {"state": "idle", "sessionId": "s"}})
        return pane

    def screen(self, member: str, pane: str) -> str:
        return subprocess.run(
            tmuxctl.tmux_command(self.slug, member, "capture-pane", "-p", "-t", "tmc-" + pane),
            stdout=subprocess.PIPE,
            text=True,
        ).stdout

    def test_tasks_run_in_an_idle_session_and_results_return(self) -> None:
        my_pane = self.idle_session(self.me)
        their_pane = self.idle_session(self.partner)
        busy_pane = self.idle_session(self.partner)
        sessionstate.update(self.slug, self.partner, busy_pane, {"claude": {"state": "working"}})

        task = board.post(self.slug, self.me, self.partner, "Rename the API", from_pane=my_pane)
        report = board.dispatch_once(self.slug, self.partner)

        self.assertEqual(report["delivered"], [task["id"]])
        time.sleep(0.5)
        self.assertIn("Rename the API", self.screen(self.partner, their_pane))
        self.assertNotIn("Rename the API", self.screen(self.partner, busy_pane))
        delivered = next(t for t in board.tasks(self.slug) if t["id"] == task["id"])
        self.assertEqual((delivered["status"], delivered["pane"]), ("delivered", their_pane))

        board.decide(self.slug, self.partner, task["id"], "completed", result="Renamed to v2")
        results = board.dispatch_once(self.slug, self.me)
        self.assertEqual(results["results"], [task["id"]])
        time.sleep(0.5)
        self.assertIn("Renamed to v2", self.screen(self.me, my_pane))

    def test_tasks_wait_in_the_queue_when_every_session_is_busy(self) -> None:
        task = board.post(self.slug, self.me, self.partner, "Later")
        report = board.dispatch_once(self.slug, self.partner)
        self.assertEqual(report["queued"], [task["id"]])
        self.assertEqual(board.dispatch_once(self.slug, self.partner)["queued"], [])


class MCPTests(BoardTestCase):
    def call(self, messages):
        environment = dict(os.environ, TMC_PROJECT=self.slug, TMC_PANE_ID=str(uuid.uuid4()))
        result = subprocess.run(
            [sys.executable, "-I", TMC, "mcp"],
            input="".join(json.dumps(message) + "\n" for message in messages),
            env=environment,
            stdout=subprocess.PIPE,
            text=True,
            check=True,
        )
        return [json.loads(line) for line in result.stdout.splitlines()]

    def test_protocol_handshake_tools_and_calls(self) -> None:
        responses = self.call(
            [
                {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                {
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "tools/call",
                    "params": {
                        "name": "post_task",
                        "arguments": {"to": self.partner, "title": "Review PR 12", "details": "Look at auth"},
                    },
                },
                {
                    "jsonrpc": "2.0",
                    "id": 4,
                    "method": "tools/call",
                    "params": {"name": "update_task", "arguments": {"id": "nope", "status": "completed"}},
                },
                {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "team_status", "arguments": {}}},
            ]
        )

        self.assertEqual([response["id"] for response in responses], [1, 2, 3, 4, 5])
        self.assertEqual(responses[0]["result"]["protocolVersion"], "2025-06-18")
        self.assertEqual(responses[0]["result"]["serverInfo"]["name"], "termuctive")
        names = [tool["name"] for tool in responses[1]["result"]["tools"]]
        self.assertEqual(names, ["team_status", "post_task", "list_tasks", "update_task", "send_message"])
        posted = json.loads(responses[2]["result"]["content"][0]["text"])["posted"]
        self.assertEqual((posted["to"], posted["title"]), (self.partner, "Review PR 12"))
        self.assertTrue(responses[3]["result"]["isError"])
        team = json.loads(responses[4]["result"]["content"][0]["text"])
        self.assertEqual(len(team["openTasks"]), 1)
        self.assertEqual(board.inbox(self.slug, self.partner)[0]["title"], "Review PR 12")


if __name__ == "__main__":
    unittest.main()
