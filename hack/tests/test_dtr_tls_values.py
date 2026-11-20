"""Regression checks for the DTR 0.9 ingress TLS values in the umbrella."""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text()


class DigitalTwinRegistryTlsValuesTests(unittest.TestCase):
    def test_tls_overlay_uses_dtr_chart_object_shape_and_aligned_host(self) -> None:
        overlay = read("charts/umbrella/values-tls.yaml")
        block_match = re.search(
            r"(?ms)^  digital-twin-bundle:\n(.*?)(?=^  data-persistence-layer-bundle:)",
            overlay,
        )
        self.assertIsNotNone(block_match, "DTR overlay section is missing")
        block = block_match.group(1)
        self.assertRegex(block, r'(?m)^\s+host: "dataprovider-dtr\.tx\.test"$')
        self.assertRegex(
            block,
            r'(?ms)^\s+tls:\n\s+enabled: true\n\s+secretName: "dataprovider-dtr-tls"$',
        )
        self.assertNotRegex(block, r"(?m)^\s+tls: true$")

        defaults = read("charts/digital-twin-bundle/values.yaml")
        rules = re.search(
            r"(?ms)^    ingress:\n.*?^      rules:\n(.*?)(?=^      className:)",
            defaults,
        )
        self.assertIsNotNone(rules, "DTR ingress host rule is missing")
        self.assertRegex(rules.group(1), r"(?m)^\s+- host: dataprovider-dtr\.tx\.test$")

    def test_pinned_dtr_chart_tls_inputs_remain_scoped_to_dtr(self) -> None:
        chart = read("charts/digital-twin-bundle/Chart.yaml")
        self.assertRegex(
            chart,
            r"(?ms)- name: digital-twin-registry\n\s+version: 0\.9\.0\n"
            r"\s+repository: https://eclipse-tractusx\.github\.io/charts/dev",
        )
        overlay = read("charts/umbrella/values-tls.yaml")
        self.assertEqual(overlay.count('secretName: "dataprovider-dtr-tls"'), 1)


if __name__ == "__main__":
    unittest.main()
