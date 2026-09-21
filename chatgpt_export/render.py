from __future__ import annotations

from typing import Any


def conversation_markdown(conversation: dict[str, Any]) -> str:
    title = str(conversation.get("title") or "Untitled")
    lines = [f"# {title}", ""]
    mapping = conversation.get("mapping")
    if not isinstance(mapping, dict):
        return "\n".join(lines + ["_Raw conversation graph preserved in `raw.json`._", ""])
    root_ids = [node_id for node_id, node in mapping.items() if isinstance(node, dict) and node.get("parent") is None]
    visited: set[str] = set()
    queue = list(root_ids or mapping.keys())
    while queue:
        node_id = str(queue.pop(0))
        if node_id in visited:
            continue
        visited.add(node_id)
        node = mapping.get(node_id)
        if not isinstance(node, dict):
            continue
        message = node.get("message")
        if isinstance(message, dict):
            role = ((message.get("author") or {}).get("role") if isinstance(message.get("author"), dict) else None) or "unknown"
            content = message.get("content")
            text = _extract_text(content)
            if text:
                lines.extend([f"## {str(role).capitalize()}", "", text, ""])
        children = node.get("children")
        if isinstance(children, list):
            queue.extend(str(x) for x in children)
    lines.extend(["---", "", "_This Markdown is a derived view. `raw.json` is the archival source of truth._", ""])
    return "\n".join(lines)


def _extract_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, dict):
        return ""
    parts = content.get("parts")
    if isinstance(parts, list):
        out: list[str] = []
        for part in parts:
            if isinstance(part, str):
                out.append(part)
            elif isinstance(part, dict):
                if isinstance(part.get("text"), str):
                    out.append(part["text"])
                elif part.get("content_type") == "image_asset_pointer":
                    out.append("[image asset]")
        return "\n".join(x for x in out if x)
    text = content.get("text")
    return text if isinstance(text, str) else ""
