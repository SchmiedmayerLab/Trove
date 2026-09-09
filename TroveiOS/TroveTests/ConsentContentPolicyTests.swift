//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Testing
@testable import Trove


struct ConsentContentPolicyTests {
    @Test(arguments: [
        "Plain text.\nA second line.\n\nAnother paragraph.",
        "---\ntitle: Consent\nversion: 1.0.0\n---\nReview this document.",
        "A hard line break.  \nNext line.",
        #"Escaped literal: \!\[example](image.png)."#,
        #"Escaped literal: \`example\`."#,
        #"<toggle id="agree" expected-value="true">I agree.</toggle>"#,
        #"<toggle id="decline" expected-value="false" initial-value="true">Optional participation.</toggle>"#,
        #"<toggle id="agree">I agree.<footnote>Additional explanation.</footnote></toggle>"#,
        #"<select id="choice" expected-value="*">Choose one.<option id="yes">Yes</option><option id="no">No</option></select>"#,
        #"<signature id="signature"/>"#
    ])
    func acceptsSupportedTextAndControls(markdown: String) throws {
        try ConsentContentPolicy.validate(markdown: markdown)
    }

    @Test(arguments: [
        "![image](https://example.test/image.png)",
        "![image][source]\n\n[source]: https://example.test/image.png",
        "![image][]\n\n[image]: https://example.test/image.png",
        "![image]\n\n[image]: https://example.test/image.png",
        "**![image](https://example.test/image.png)**",
        "[![image](https://example.test/image.png)](https://example.test)",
        "- ![image](https://example.test/image.png)",
        "| Image |\n| --- |\n| ![image](https://example.test/image.png) |",
        "<img src=\"https://example.test/image.png\" />",
        "<div>Unsupported HTML</div>",
        "[Link](https://example.test)",
        #"Escaping only the image marker leaves a link: \![example](image.png)."#,
        "**Strong text**", "*Emphasis*", "~~Removed~~", "# Heading", "> Quote", "- Item", "1. Item", "---",
        "`![literal](image.png)`", "```\n![literal](image.png)\n```",
        "```\n<toggle id=\"not-a-control\">Example</toggle>\n```"
    ])
    func rejectsUnsupportedRenderedContent(markdown: String) {
        #expect(throws: ConsentContentPolicy.ValidationError.self) {
            try ConsentContentPolicy.validate(markdown: markdown)
        }
    }

    @Test(arguments: ["toggle", "select", "option", "footnote"])
    func rejectsImagesAndReferencesInsideEveryLabel(location: String) {
        for image in ["![image](image.png)", "![image][source]\n\n[source]: image.png"] {
            let markdown: String
            switch location {
            case "toggle": markdown = "<toggle id=\"a\">\(image)</toggle>"
            case "select": markdown = "<select id=\"a\">\(image)<option id=\"yes\">Yes</option></select>"
            case "option": markdown = "<select id=\"a\"><option id=\"yes\">\(image)</option></select>"
            default: markdown = "<toggle id=\"a\">Agree.<footnote>\(image)</footnote></toggle>"
            }
            #expect(throws: ConsentContentPolicy.ValidationError.self) {
                try ConsentContentPolicy.validate(markdown: markdown)
            }
        }
    }

    @Test(arguments: [
        #"<toggle id="a">**Formatted label**</toggle>"#,
        #"<toggle id="a">&amp;</toggle>"#,
        #"<toggle id="a">\*Escaped label\*</toggle>"#,
        #"<toggle id="a" expected-value="maybe">Agree</toggle>"#,
        #"<toggle id="a" id="b">Agree</toggle>"#,
        #"<toggle id="a">Agree</toggle>\n<signature id="a"/>"#,
        #"<select id="a" expected-value="missing"><option id="yes">Yes</option></select>"#,
        #"<select id="a"><option id="yes">Yes</option><option id="yes">Again</option></select>"#,
        #"<select id="a"/>"#,
        #"<signature id="a">Ignored content</signature>"#,
        #"<toggle id="a">Missing closing tag"#,
        #"<toggle id="a"><footnote><footnote>Nested</footnote></footnote></toggle>"#,
        #"<unknown id="a">Unsupported</unknown>"#,
        "<!-- Unclosed comment"
    ])
    func rejectsLossyLabelsAndInvalidControls(markdown: String) {
        #expect(throws: ConsentContentPolicy.ValidationError.self) {
            try ConsentContentPolicy.validate(markdown: markdown)
        }
    }
}
