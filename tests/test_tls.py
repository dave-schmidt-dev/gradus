"""The provider TLS context always carries the bundled certifi trust store."""

from __future__ import annotations

import re
import ssl
import unittest
from pathlib import Path
from unittest.mock import patch

from gradus import tls


class DefaultSSLContextTests(unittest.TestCase):
    def test_context_verifies_and_checks_hostnames(self) -> None:
        context = tls.default_ssl_context()
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(context.check_hostname)

    def test_bundled_ca_file_is_the_packaged_certifi_bundle(self) -> None:
        bundled = tls.bundled_ca_file()
        self.assertTrue(bundled.is_absolute())
        self.assertTrue(bundled.is_file())
        self.assertEqual(bundled.name, "cacert.pem")
        self.assertIn(b"-----BEGIN CERTIFICATE-----", bundled.read_bytes())

    def test_bundle_is_loaded_even_when_the_interpreter_finds_no_store(self) -> None:
        """The frozen runtime's OPENSSLDIR is absent; the bundle must still load."""
        real_create = ssl.create_default_context

        def empty_default_context(*args, **kwargs):
            context = real_create(*args, **kwargs)
            # Simulate an interpreter whose default paths yielded nothing.
            context.set_default_verify_paths = lambda: None
            return context

        with patch.object(ssl, "create_default_context", side_effect=empty_default_context):
            context = tls.default_ssl_context()
        self.assertGreater(len(context.get_ca_certs()), 100)

    def test_trust_report_is_credential_free_and_names_the_bundle(self) -> None:
        report = tls.trust_report()
        self.assertEqual(
            sorted(report),
            [
                "bundled_ca_file",
                "ca_certificates",
                "check_hostname",
                "frozen",
                "interpreter_ca_certificates",
                "openssl_cafile",
                "openssl_capath",
                "verify_mode",
            ],
        )
        self.assertEqual(Path(report["bundled_ca_file"]), tls.bundled_ca_file())
        self.assertGreater(report["ca_certificates"], 100)
        self.assertGreaterEqual(report["ca_certificates"], report["interpreter_ca_certificates"])
        self.assertEqual(report["verify_mode"], "CERT_REQUIRED")
        self.assertTrue(report["check_hostname"])
        self.assertIs(report["frozen"], False)


class ProviderCallSitesTests(unittest.TestCase):
    def test_every_provider_urlopen_passes_the_shared_context(self) -> None:
        """A new urlopen without `context=` silently regresses to the empty store."""
        providers_dir = Path(tls.__file__).resolve().parent / "providers"
        offenders: list[str] = []
        for path in sorted(providers_dir.glob("*.py")):
            text = path.read_text(encoding="utf-8")
            for match in re.finditer(r"urlopen\(", text):
                call = text[match.end() : match.end() + 200]
                if "context=default_ssl_context()" not in call:
                    offenders.append(f"{path.name}:{text.count(chr(10), 0, match.start()) + 1}")
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()
