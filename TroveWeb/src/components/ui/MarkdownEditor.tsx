//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { Button, Separator } from "@schmiedmayerlab/grove-design-system";
import { TableKit } from "@tiptap/extension-table";
import { EditorContent, useEditor, type Storage } from "@tiptap/react";
import { StarterKit } from "@tiptap/starter-kit";
import {
  Bold,
  Italic,
  Strikethrough,
  Code,
  Heading1,
  Heading2,
  Heading3,
  List,
  ListOrdered,
  Minus,
} from "lucide-react";
import { useEffect, useRef, type ComponentProps } from "react";
import { Markdown } from "tiptap-markdown";
import { cn } from "@/utils/cn";

interface ToggleProps extends Omit<
  ComponentProps<typeof Button>,
  "variant" | "size" | "onClick"
> {
  pressed?: boolean;
  onPressedChange?: () => void;
}

const Toggle = ({
  pressed,
  onPressedChange,
  className,
  ...props
}: ToggleProps) => {
  return (
    <Button
      size="sm"
      type="button"
      variant="ghost"
      onClick={onPressedChange}
      className={cn(
        "[&_svg]:size-4 [&_svg]:opacity-80",
        pressed && "bg-fill-tertiary",
        className,
      )}
      {...props}
    />
  );
};

interface MarkdownStorage extends Storage {
  markdown: { getMarkdown: () => string };
}

interface MarkdownEditorProps extends Omit<ComponentProps<"div">, "onChange"> {
  value?: string;
  onChange?: (value: string) => void;
  readOnly?: boolean;
}

export const MarkdownEditor = ({
  value,
  onChange,
  readOnly = false,
  className,
  ...props
}: MarkdownEditorProps) => {
  const currentValueRef = useRef(value ?? "");
  const editor = useEditor({
    extensions: [
      // Automatic trailing paragraphs can mutate Markdown on focus alone.
      StarterKit.configure({ trailingNode: false }),
      TableKit,
      Markdown.configure({ html: false }),
    ],
    content: value,
    editable: !readOnly,
    onUpdate: ({ editor }) => {
      const storage = editor.storage as MarkdownStorage;
      const markdown = storage.markdown.getMarkdown();
      currentValueRef.current = markdown;
      onChange?.(markdown);
    },
    editorProps: {
      attributes: {
        class: cn(
          "min-h-44 p-4 outline-none whitespace-pre-wrap",
          "[&_strong]:font-semibold",
          "[&_ul]:list-disc [&_ul]:my-1 [&_ul]:pl-4",
          "[&_ol]:list-decimal [&_ol]:my-1 [&_ol]:pl-4",
          "[&_li]:marker:text-text-tertiary",
          "[&_h1]:text-2xl [&_h1]:font-semibold [&_h1]:mb-1 [&_h1]:text-text",
          "[&_h2]:text-xl [&_h2]:font-medium [&_h2]:mb-1",
          "[&_h3]:text-lg [&_h3]:mb-1",
          "[&_h4]:font-semibold [&_h5]:font-semibold [&_h6]:font-semibold [&_h6]:italic",
          "[&_p]:my-2 [&_blockquote]:border-l-2 [&_blockquote]:pl-4",
          "[&_table]:w-full [&_td]:border [&_td]:p-2 [&_th]:border [&_th]:p-2 [&_th]:text-left",
          "[&_a]:text-blue-600 [&_a]:underline [&_pre]:overflow-x-auto [&_pre]:bg-fill-tertiary [&_pre]:p-3",
        ),
      },
    },
  });

  useEffect(() => {
    if (currentValueRef.current !== (value ?? "")) {
      currentValueRef.current = value ?? "";
      editor.commands.setContent(value ?? "", { emitUpdate: false });
    }
  }, [value, editor]);

  useEffect(() => {
    editor.setEditable(!readOnly, false);
  }, [editor, readOnly]);

  return (
    <div
      className={cn(
        "border-border bg-fill-secondary flex min-h-20 w-full flex-col rounded-md border text-sm",
        "placeholder:text-text-tertiary",
        "disabled:cursor-not-allowed disabled:opacity-50",
        // Ring offset styles
        "has-[.ProseMirror:focus]:ring-offset-surface has-[.ProseMirror:focus]:ring-ring has-[.ProseMirror:focus]:ring-2 has-[.ProseMirror:focus]:ring-offset-2",
        className,
        readOnly &&
          "min-h-0 border-0 bg-transparent [&_.ProseMirror]:min-h-0 [&_.ProseMirror]:p-0",
      )}
      {...props}
    >
      {!readOnly && (
        <div className="flex flex-wrap items-center gap-1 border-b p-2">
          <Toggle
            aria-label="Bold"
            pressed={editor.isActive("bold")}
            onPressedChange={() => editor.chain().focus().toggleBold().run()}
            disabled={!editor.can().chain().focus().toggleBold().run()}
          >
            <Bold />
          </Toggle>

          <Toggle
            aria-label="Italic"
            pressed={editor.isActive("italic")}
            onPressedChange={() => editor.chain().focus().toggleItalic().run()}
            disabled={!editor.can().chain().focus().toggleItalic().run()}
          >
            <Italic />
          </Toggle>

          <Toggle
            aria-label="Strikethrough"
            pressed={editor.isActive("strike")}
            onPressedChange={() => editor.chain().focus().toggleStrike().run()}
            disabled={!editor.can().chain().focus().toggleStrike().run()}
          >
            <Strikethrough />
          </Toggle>

          <Toggle
            aria-label="Inline code"
            pressed={editor.isActive("code")}
            onPressedChange={() => editor.chain().focus().toggleCode().run()}
            disabled={!editor.can().chain().focus().toggleCode().run()}
          >
            <Code />
          </Toggle>
          <Separator orientation="vertical" className="h-6" />
          <Toggle
            aria-label="Heading 1"
            pressed={editor.isActive("heading", { level: 1 })}
            onPressedChange={() =>
              editor.chain().focus().toggleHeading({ level: 1 }).run()
            }
          >
            <Heading1 />
          </Toggle>

          <Toggle
            aria-label="Heading 2"
            pressed={editor.isActive("heading", { level: 2 })}
            onPressedChange={() =>
              editor.chain().focus().toggleHeading({ level: 2 }).run()
            }
          >
            <Heading2 />
          </Toggle>

          <Toggle
            aria-label="Heading 3"
            pressed={editor.isActive("heading", { level: 3 })}
            onPressedChange={() =>
              editor.chain().focus().toggleHeading({ level: 3 }).run()
            }
          >
            <Heading3 />
          </Toggle>
          <Separator orientation="vertical" className="h-6" />
          <Toggle
            aria-label="Bullet list"
            pressed={editor.isActive("bulletList")}
            onPressedChange={() =>
              editor.chain().focus().toggleBulletList().run()
            }
          >
            <List />
          </Toggle>

          <Toggle
            aria-label="Numbered list"
            pressed={editor.isActive("orderedList")}
            onPressedChange={() =>
              editor.chain().focus().toggleOrderedList().run()
            }
          >
            <ListOrdered />
          </Toggle>
          <Separator orientation="vertical" className="h-6" />
          <Button
            type="button"
            aria-label="Horizontal rule"
            size="sm"
            variant="ghost"
            onClick={() => editor.chain().focus().setHorizontalRule().run()}
          >
            <Minus className="size-4 opacity-80" />
          </Button>
        </div>
      )}

      <EditorContent editor={editor} />
    </div>
  );
};
