#!/usr/bin/env python3
"""Regenerates Sources/SwitcherCore/Shell/EmbeddedScripts.swift from the files in Wrapper/."""
import pathlib
root = pathlib.Path(__file__).resolve().parent.parent
w = (root/"Wrapper/aiswitch-wrapper.sh").read_text()
s = (root/"Wrapper/aiswitch-statusline.sh").read_text()
for name, text in (("wrapper", w), ("statusline", s)):
    assert '"##' not in text and '##"' not in text, name
out = '''import Foundation

// GENERATED from Wrapper/aiswitch-wrapper.sh and Wrapper/aiswitch-statusline.sh by Scripts/sync-embedded-scripts.py.
// Do not edit by hand; a unit test asserts these strings equal the files in the repository.
public enum EmbeddedScripts {
    public static let wrapperVersion = 1

    public static let wrapper = ##"""
%s"""##

    public static let statusLine = ##"""
%s"""##
}
''' % (w, s)
(root/"Sources/SwitcherCore/Shell/EmbeddedScripts.swift").write_text(out)
print("EmbeddedScripts.swift regenerated")
