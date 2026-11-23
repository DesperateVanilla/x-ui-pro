import pathlib
import shlex
import subprocess
import sys
import tempfile
import unittest

from test_installer import find_bash


ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = ("x-ui-pro.sh", "x-ui-latest.sh", "change_domain.sh")


def dns_helpers(name: str) -> str:
    content = (ROOT / name).read_text(encoding="utf-8")
    start = content.index("# DNS helpers\n")
    end = content.index("# End DNS helpers\n", start)
    return content[start:end]


def run_dns(
    name: str, answers: list[dict[str, str]], ipv6: str = "",
    domains: tuple[str, str] = ("panel.example.com", "reality.example.com"),
) -> subprocess.CompletedProcess[str]:
    cases = []
    for attempt, overrides in enumerate(answers):
        for query, response in overrides.items():
            if response == "DIG_FAILURE":
                action = "return 9"
            else:
                if not response.startswith(";;"):
                    response = ";; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n" + response
                action = f"printf '%s\\n' {shlex.quote(response)}"
            cases.append(f"{shlex.quote(f'{attempt}:{query}')}) {action} ;;")
    with tempfile.TemporaryDirectory(prefix="installer dns ") as temp:
        runner = pathlib.Path(temp) / "dns.sh"
        runner.write_text(
            "#!/bin/bash\nset -eu\n"
            f'python3() {{ {shlex.quote(pathlib.Path(sys.executable).as_posix())} "$@"; }}\n'
            "attempt=0\n"
            "dig() {\n"
            '  local host="${@: -2:1}" type="${@: -1}" resolver="system" arg\n'
            '  for arg in "$@"; do [[ "$arg" != @* ]] || resolver="${arg#@}"; done\n'
            '  case "$attempt:$resolver:$host:$type" in\n'
            + "\n".join(cases)
            + '\n    *) echo ";; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1"; '
            'if [[ "$type" == A ]]; then printf "%s 60 IN A 203.0.113.10\\n" "$host"; fi ;;\n'
            "  esac\n}\n"
            'sleep() { [[ "$1" == 15 ]]; attempt=$((attempt + 1)); '
            f'if (( attempt >= {len(answers)} )); then echo "unexpected retry" >&2; exit 42; fi; }}\n'
            'IP4="203.0.113.10"\n'
            f"IP6={shlex.quote(ipv6)}\n"
            + dns_helpers(name)
            + '\nwait_for_dns ' + ' '.join(shlex.quote(domain) for domain in domains) + '\n'
            + 'printf "READY:%s\\n" "$attempt"\n',
            encoding="utf-8",
            newline="\n",
        )
        return subprocess.run(
            [find_bash(), runner.as_posix()], capture_output=True, text=True, timeout=15,
        )


class TestDNSWait(unittest.TestCase):
    def check_answers(self, answers: list[dict[str, str]], ipv6: str = "") -> None:
        for name in SCRIPTS:
            with self.subTest(script=name):
                result = run_dns(name, answers, ipv6)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(f"READY:{len(answers) - 1}", result.stdout)

    def test_ready_immediately(self) -> None:
        self.check_answers([{}])

    def test_waits_for_missing_and_stale_records(self) -> None:
        self.check_answers([
            {"system:panel.example.com:A": ""},
            {"system:panel.example.com:A": "panel.example.com. 60 IN A 198.51.100.2"},
            {},
        ])

    def test_waits_for_both_public_resolvers(self) -> None:
        self.check_answers([
            {"1.1.1.1:reality.example.com:A": ""},
            {"8.8.8.8:reality.example.com:A": "reality.example.com. 60 IN A 198.51.100.2"},
            {},
        ])

    def test_rejects_mixed_a_records(self) -> None:
        self.check_answers([
            {"system:panel.example.com:A": "panel.example.com. 60 IN A 203.0.113.10\n"
             "panel.example.com. 60 IN A 198.51.100.2"},
            {},
        ])

    def test_waits_for_wrong_aaaa_to_disappear(self) -> None:
        self.check_answers([
            {"system:panel.example.com:AAAA": "panel.example.com. 60 IN AAAA 2001:db8::99"},
            {},
        ], ipv6="2001:db8::10")

    def test_rejects_aaaa_without_server_ipv6(self) -> None:
        self.check_answers([
            {"system:panel.example.com:AAAA": "panel.example.com. 60 IN AAAA 2001:db8::10"},
            {},
        ])

    def test_accepts_equivalent_ipv6_and_cname(self) -> None:
        self.check_answers([{
            "system:panel.example.com:A": "panel.example.com. 60 IN CNAME origin.example.com.\n"
            "origin.example.com. 60 IN A 203.0.113.10",
            "system:panel.example.com:AAAA": "panel.example.com. 60 IN CNAME origin.example.com.\n"
            "origin.example.com. 60 IN AAAA 2001:0db8:0000:0000:0000:0000:0000:0010",
        }], ipv6="2001:db8::10")

    def test_rechecks_first_domain_while_waiting_for_second(self) -> None:
        self.check_answers([
            {"system:reality.example.com:A": ""},
            {"system:panel.example.com:A": ""},
            {},
        ])

    def test_retries_failed_query(self) -> None:
        self.check_answers([{"system:panel.example.com:A": "DIG_FAILURE"}, {}])

    def test_retries_aaaa_servfail(self) -> None:
        self.check_answers([
            {"system:panel.example.com:AAAA": ";; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1"},
            {},
        ])

    def test_rejects_identical_or_invalid_domains_before_waiting(self) -> None:
        for name in SCRIPTS:
            for domains in (
                ("same.example.com", "same.example.com"),
                ("https://panel.example.com", "reality.example.com"),
                ("@1.1.1.1", "reality.example.com"),
                ("", "reality.example.com"),
                ("203.0.113.10", "reality.example.com"),
            ):
                with self.subTest(script=name, domains=domains):
                    result = run_dns(name, [{}], domains=domains)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn("DNS pending", result.stdout)
                    self.assertNotIn("unexpected retry", result.stderr)


if __name__ == "__main__":
    unittest.main()
