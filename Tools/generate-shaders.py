#!/usr/bin/env python3
"""Generate embedded fallbacks from canonical production and diagnostic Metal.

The main SDK loads an ahead-of-time metallib if the application bundles one.
SwiftPM and standalone diagnostic processes can compile these generated sources
without a custom build plugin. Do not edit generated headers directly.
"""
from pathlib import Path
import argparse

root = Path(__file__).resolve().parent.parent


def quote(line: str) -> str:
    return '"' + line.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def literal_lines(path: Path) -> str:
    return "\n".join("    " + quote(line) for line in path.read_text().splitlines(keepends=True))


def production() -> str:
    return (
        "// Generated from Shaders/Production.metal by Tools/generate-shaders.py.\n"
        "// Do not edit. SwiftPM can compile without bundled metallib resources.\n"
        "#pragma once\n"
        "static constexpr const char *kMCProductionMetalSource =\n"
        + literal_lines(root / "Shaders/Production.metal")
        + ";\n"
    )


def diagnostic() -> str:
    return (
        "// Generated from Shaders/Diagnostic.metal by Tools/generate-shaders.py.\n"
        "// Diagnostic/test shader only; never used by the production SDK.\n"
        "#pragma once\n"
        '#import <Foundation/Foundation.h>\n'
        "static constexpr const char *kMCDiagnosticMetalSource =\n"
        + literal_lines(root / "Shaders/Diagnostic.metal")
        + ";\n"
        "static inline NSString *MCDiagnosticShaderSource(void) {\n"
        "    return [NSString stringWithUTF8String:kMCDiagnosticMetalSource];\n"
        "}\n"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    def legacy() -> str:
        return (
            "// Generated from Shaders/LegacyDemo.metal by Tools/generate-shaders.py.\n"
            "// Legacy diagnostic shader only; not linked to production SDK.\n"
            "#pragma once\n"
            '#import <Foundation/Foundation.h>\n'
            "static constexpr const char *kMCLegacyDemoMetalSource =\n"
            + literal_lines(root / "Shaders/LegacyDemo.metal")
            + ";\n"
            "static inline NSString *MCLegacyDemoShaderSource(void) {\n"
            "    return [NSString stringWithUTF8String:kMCLegacyDemoMetalSource];\n"
            "}\n"
        )

    outputs = {
        root / "Sources/MetalCadence/internal/MCProductionShaderSource.hpp": production(),
        root / "Tools/SceneShader.h": diagnostic(),
        root / "Tools/LegacyDemoShader.h": legacy(),
    }

    for destination, expected in outputs.items():
        if args.check:
            if not destination.exists() or destination.read_text() != expected:
                raise SystemExit(
                    f"{destination.relative_to(root)} is stale. "
                    "Run python3 Tools/generate-shaders.py."
                )
            print("Verified", destination.relative_to(root))
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(expected)
            print("Generated", destination.relative_to(root))
