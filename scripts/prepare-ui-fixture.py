#!/usr/bin/env python3
"""Build a deterministic, offline-only Minimail app for manual UI QA.

The generated bundle uses its own bundle identifier and a helper wrapper that
pins every CLI invocation to .build/ui-qa/email-cli.db.  Commands that could
touch Resend, deliver mail, install a daemon, or modify the user's real setup
are rejected before the real email-cli process starts.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import shutil
import sqlite3
import stat
import struct
import zlib
import subprocess
import sys
import textwrap
from datetime import datetime, timedelta, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / ".build"
QA_DIR = BUILD / "ui-qa"
DB_PATH = QA_DIR / "email-cli.db"
APP_PATH = BUILD / "MinimailQA.app"
DEBUG_BINARY = BUILD / "debug" / "Minimail"
CLI_ENGINE = ROOT.parent / "email-cli" / "target" / "release" / "email-cli"

ACCOUNTS = (
    ("alex@minimail.test", "Alex Morgan", 1),
    ("studio@minimail.test", "Minimail Studio", 0),
)

SUBJECTS = (
    "Design review notes",
    "Your train itinerary",
    "Invoice ready for review",
    "Weekend plans",
    "Release checklist",
    "Photos from the workshop",
    "Lunch next Thursday?",
    "Account activity summary",
    "Project Juniper update",
    "A quick introduction",
    "Meeting moved to 14:30",
    "September reading list",
)

SENDERS = (
    ("Maya Chen", "maya@correspondent.test"),
    ("Noah Williams", "noah@correspondent.test"),
    ("Priya Shah", "priya@correspondent.test"),
    ("Leo Martin", "leo@correspondent.test"),
    ("Sofia Rossi", "sofia@correspondent.test"),
    ("Operations", "ops@service.test"),
    ("The Field Notes", "editor@newsletter.test"),
    ("Jamie Park", "jamie@correspondent.test"),
)


def run_checked(command: list[str], *, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def require_file(path: Path, description: str) -> None:
    if not path.is_file():
        raise SystemExit(f"missing {description}: {path}")


def initialise_schema() -> None:
    QA_DIR.mkdir(parents=True, exist_ok=True)
    run_checked([str(CLI_ENGINE), "--db", str(DB_PATH), "account", "list", "--json"], capture=True)


def make_long_html() -> tuple[str, str]:
    paragraphs = []
    text_lines = []
    for index in range(1, 35):
        line = (
            f"Section {index}: The team reviewed the current milestone, captured the open "
            "questions, and agreed on a small next step that can be checked independently."
        )
        paragraphs.append(f"<p><strong>Section {index}</strong> — {line.split(': ', 1)[1]}</p>")
        text_lines.append(line)

    html = """<!doctype html>
<html><body>
<div style="background:#183c54;color:white;padding:12px">Quarterly project review</div>
<img src="cid:qa-logo" width="160" height="48" alt="Embedded blue banner">
<table width="720"><tr><td>Wide table: start</td><td align="right">Wide table: end</td></tr></table>
<p>Hello Alex,</p>
<p>This deliberately long message exercises reader width, scrolling, links,
typography, quoted replies, and protected remote content.</p>
{paragraphs}
<blockquote>
  <p>On the previous review, Maya wrote:</p>
  <p>Please keep the next release focused, readable, and easy to reverse.</p>
</blockquote>
<p><a href="https://notes.example.invalid/project-review">Open project notes</a></p>
<img src="https://remote-content.example.invalid/tracking-pixel.png"
     width="1" height="1" alt="Remote content QA marker">
<p>Best,<br>Maya</p>
</body></html>""".format(paragraphs="\n".join(paragraphs))

    text = "\n\n".join(
        [
            "Quarterly project review",
            "Hello Alex,",
            "This deliberately long message exercises reader width, scrolling, links, typography, quoted replies, and protected remote content.",
            *text_lines,
            "> On the previous review, Maya wrote:\n> Please keep the next release focused, readable, and easy to reverse.",
            "Best,\nMaya",
        ]
    )
    return text, html


def seed_database() -> None:
    attachment_dir = QA_DIR / "attachments"
    attachment_dir.mkdir(parents=True, exist_ok=True)
    attachment_path = attachment_dir / "release-checklist.txt"
    attachment_path.write_text(
        "Minimail QA attachment\n\n- Check navigation\n- Check reader\n- Check compose\n",
        encoding="utf-8",
    )

    # A deterministic PNG fixture, with no remote dependency.
    def png_chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    pixels = b"".join(b"\x00" + bytes([30, 115, 195]) * 160 for _ in range(48))
    image_path = attachment_dir / "embedded-banner.png"
    image_path.write_bytes(b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", struct.pack(">IIBBBBB", 160, 48, 8, 2, 0, 0, 0))
                          + png_chunk(b"IDAT", zlib.compress(pixels)) + png_chunk(b"IEND", b""))

    long_text, long_html = make_long_html()
    base_time = datetime(2026, 9, 16, 8, 30, tzinfo=timezone.utc)

    connection = sqlite3.connect(DB_PATH)
    connection.execute("PRAGMA foreign_keys = ON")
    try:
        with connection:
            connection.execute(
                "INSERT INTO profiles (name, api_key, created_at, updated_at) VALUES (?, ?, ?, ?)",
                ("qa-fixture", "offline-placeholder.test", "2026-01-01 00:00:00", "2026-01-01 00:00:00"),
            )
            connection.executemany(
                """
                INSERT INTO accounts
                    (email, profile_name, display_name, signature, is_default, created_at, updated_at)
                VALUES (?, 'qa-fixture', ?, ?, ?, '2026-01-01 00:00:00', '2026-01-01 00:00:00')
                """,
                [
                    (
                        email,
                        name,
                        f"Best,\n{name}",
                        is_default,
                    )
                    for email, name, is_default in ACCOUNTS
                ],
            )

            message_ids: list[int] = []
            for account_index, (account, display_name, _) in enumerate(ACCOUNTS):
                for index in range(72):
                    serial = account_index * 72 + index + 1
                    sent = index % 6 == 5
                    archived = index % 9 == 8
                    starred = index % 7 == 2
                    unread = not sent and index % 3 != 0
                    sender_name, sender_email = SENDERS[index % len(SENDERS)]
                    created = base_time - timedelta(hours=4 * serial + account_index)
                    created_string = created.isoformat().replace("+00:00", "Z")
                    subject = SUBJECTS[index % len(SUBJECTS)]
                    if account_index:
                        subject = f"Studio: {subject}"

                    direction = "sent" if sent else "received"
                    from_addr = f"{display_name} <{account}>" if sent else f"{sender_name} <{sender_email}>"
                    to = [f"{sender_name} <{sender_email}>"] if sent else [f"{display_name} <{account}>"]
                    cc = ["Review Group <review@minimail.test>"] if index % 11 == 4 else []
                    bcc = ["Archive <archive@minimail.test>"] if sent and index % 12 == 5 else []
                    body = (
                        f"Hi {display_name.split()[0]},\n\n"
                        f"This is deterministic QA message {serial}. It covers {subject.lower()} and gives the list row enough text for a useful preview.\n\n"
                        f"Regards,\n{sender_name if not sent else display_name}"
                    )
                    html_body = None
                    list_unsubscribe = None
                    if index == 0 and account_index == 0:
                        subject = "Quarterly project review — long HTML & privacy test"
                        body = long_text
                        html_body = long_html
                    elif index % 17 == 6:
                        subject = f"{subject} — newsletter edition"
                        html_body = (
                            "<html><body><h2>Field Notes</h2><p>A compact rich-text message "
                            "with <strong>bold text</strong>, <em>emphasis</em>, and a "
                            "<a href='https://newsletter.example.invalid/story'>reserved test link</a>.</p></body></html>"
                        )
                        list_unsubscribe = "<https://newsletter.example.invalid/unsubscribe>"

                    rfc_id = f"<qa-{serial}@minimail.test>"
                    in_reply_to = None
                    references: list[str] = []
                    if index in (1, 2):
                        in_reply_to = f"<qa-{account_index * 72 + 1}@minimail.test>"
                        references = [in_reply_to]
                        subject = "Re: Quarterly project review" if account_index == 0 else "Re: Studio planning"

                    raw = {
                        "id": f"qa-remote-{serial:03d}",
                        "from": from_addr,
                        "to": to,
                        "subject": subject,
                        "created_at": created_string,
                        "fixture": True,
                    }
                    cursor = connection.execute(
                        """
                        INSERT INTO messages (
                            remote_id, direction, account_email, from_addr, to_json, cc_json,
                            bcc_json, reply_to_json, subject, text_body, html_body,
                            rfc_message_id, in_reply_to, references_json, last_event, is_read,
                            created_at, synced_at, raw_json, archived, starred, snoozed_until,
                            list_unsubscribe
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            f"qa-remote-{serial:03d}",
                            direction,
                            account,
                            from_addr,
                            json.dumps(to),
                            json.dumps(cc),
                            json.dumps(bcc),
                            json.dumps(["replies@minimail.test"] if index % 19 == 3 else []),
                            subject,
                            body,
                            html_body,
                            rfc_id,
                            in_reply_to,
                            json.dumps(references),
                            "delivered" if sent else "received",
                            0 if unread else 1,
                            created_string,
                            created_string,
                            json.dumps(raw, sort_keys=True),
                            int(archived),
                            int(starred),
                            "2026-10-01T09:00:00Z" if index % 31 == 12 else None,
                            list_unsubscribe,
                        ),
                    )
                    message_ids.append(int(cursor.lastrowid))

            attachment_message = message_ids[4]
            connection.execute(
                """
                INSERT INTO attachments
                    (message_id, remote_attachment_id, filename, content_type, size,
                     download_url, local_path, raw_json)
                VALUES (?, ?, ?, ?, ?, NULL, ?, ?)
                """,
                (
                    attachment_message,
                    "qa-attachment-001",
                    attachment_path.name,
                    "text/plain",
                    attachment_path.stat().st_size,
                    str(attachment_path),
                    json.dumps({"fixture": True}, sort_keys=True),
                ),
            )

            for attachment_file, remote_id, mime, cid in [
                (image_path, "qa-inline-banner", "image/png", "qa-logo"),
                (attachment_path, "qa-thread-checklist", "text/plain", None),
            ]:
                connection.execute(
                    "INSERT INTO attachments (message_id, remote_attachment_id, filename, content_type, size, local_path, raw_json) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (message_ids[0], remote_id, attachment_file.name, mime, attachment_file.stat().st_size,
                     str(attachment_file), json.dumps({"content_id": cid, "content_disposition": "inline" if cid else "attachment"})),
                )

            connection.executemany(
                """
                INSERT INTO drafts (
                    id, account_email, to_json, cc_json, bcc_json, reply_to_json,
                    subject, text_body, html_body, reply_to_message_id, scheduled_at,
                    attachment_paths_json, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    (
                        "qa-rich-draft",
                        ACCOUNTS[0][0],
                        json.dumps(["Maya Chen <maya@correspondent.test>"]),
                        json.dumps(["Review Group <review@minimail.test>"]),
                        "[]",
                        json.dumps(["replies@minimail.test"]),
                        "Draft: launch notes with formatting",
                        "Hello Maya,\n\nHere are the launch notes.\n\nBest,\nAlex",
                        "<p>Hello Maya,</p><p>Here are the <strong>launch notes</strong> with an <em>emphasised detail</em>.</p><p>Best,<br>Alex</p>",
                        None,
                        None,
                        json.dumps([str(attachment_path)]),
                        "2026-09-15T14:00:00Z",
                        "2026-09-16T07:45:00Z",
                    ),
                    (
                        "qa-plain-draft",
                        ACCOUNTS[1][0],
                        json.dumps(["Noah Williams <noah@correspondent.test>"]),
                        "[]",
                        "[]",
                        "[]",
                        "Draft: plain-text follow-up",
                        "Hi Noah,\n\nFollowing up on the workshop notes.\n\nThanks,\nMinimail Studio",
                        None,
                        None,
                        "2026-09-18T09:00:00Z",
                        "[]",
                        "2026-09-15T15:00:00Z",
                        "2026-09-16T07:30:00Z",
                    ),
                ],
            )
    finally:
        connection.close()


def wrapper_source() -> str:
    return textwrap.dedent(
        """\
        #!/usr/bin/python3
        import json
        import os
        import sqlite3
        import subprocess
        import sys
        from pathlib import Path

        helper = Path(__file__).resolve()
        build_dir = helper.parents[3]
        database = build_dir / "ui-qa" / "email-cli.db"
        engine = helper.with_name("email-cli-engine")

        def emit(payload, stream=sys.stdout):
            stream.write(json.dumps(payload, sort_keys=True) + "\\n")

        def success(data):
            emit({"version": "1", "status": "success", "data": data})
            raise SystemExit(0)

        def blocked(detail):
            emit({
                "version": "1",
                "status": "error",
                "error": {
                    "code": "qa_fixture_offline",
                    "message": "Offline QA fixture blocked " + detail,
                },
            }, sys.stderr)
            raise SystemExit(2)

        original = sys.argv[1:]
        args = []
        index = 0
        while index < len(original):
            if original[index] == "--db":
                index += 2
                continue
            if original[index].startswith("--db="):
                index += 1
                continue
            args.append(original[index])
            index += 1

        words = [value for value in args if not value.startswith("-")]
        command = words[0] if words else ""
        subcommand = words[1] if len(words) > 1 else ""

        always_blocked = {
            "send", "reply", "forward", "daemon", "autostart", "update",
            "domain", "contact", "batch", "api-key", "webhook", "email",
            "broadcast", "contact-property", "topic", "segment",
        }
        if command in always_blocked:
            blocked(command)
        if command == "profile" and subcommand in {"add", "test"}:
            blocked("profile " + subcommand)
        if command == "account" and subcommand == "add":
            blocked("account add")
        if command == "account" and subcommand == "edit" and "--profile" in args:
            with sqlite3.connect(database) as connection:
                existing = connection.execute("SELECT profile_name FROM accounts WHERE email = ?", (words[2],)).fetchone()
            if not existing or args[args.index("--profile") + 1] != existing[0]:
                blocked("account profile change")
        if command == "draft" and subcommand == "send":
            blocked("draft send")
        if command == "outbox" and subcommand in {"retry", "flush"}:
            blocked("outbox " + subcommand)

        if command == "sync" or (command == "inbox" and subcommand == "sync"):
            success({})
        if command == "attachments" and subcommand == "prefetch":
            success({})
        if command == "attachments" and subcommand == "list":
            with sqlite3.connect(database) as connection:
                connection.row_factory = sqlite3.Row
                records = connection.execute(
                    "SELECT id, remote_attachment_id, filename, content_type, size, local_path, raw_json FROM attachments WHERE message_id = ? ORDER BY id",
                    (int(words[2]),),
                ).fetchall()
            rows = []
            for record in records:
                metadata = json.loads(record["raw_json"])
                rows.append({
                    "id": record["remote_attachment_id"] or str(record["id"]),
                    "filename": record["filename"], "content_type": record["content_type"], "size": record["size"],
                    "downloaded": bool(record["local_path"] and Path(record["local_path"]).is_file()),
                    "content_id": metadata.get("content_id"), "content_disposition": metadata.get("content_disposition"),
                })
            success(rows)
        if command == "attachments" and subcommand in {"get", "show"}:
            numeric = [value for value in words[2:] if value.isdigit()]
            if numeric:
                with sqlite3.connect(database) as connection:
                    local = connection.execute(
                        "SELECT local_path FROM attachments WHERE message_id = ? AND local_path IS NOT NULL LIMIT 1",
                        (int(numeric[0]),),
                    ).fetchone()
                if not local:
                    blocked("a non-local attachment download")

        environment = dict(os.environ)
        for key in list(environment):
            if "RESEND" in key.upper() or key == "MINIMAIL_RESEND_API_KEY":
                environment.pop(key, None)
        result = subprocess.run(
            [str(engine), "--db", str(database), *args],
            env=environment,
        )
        raise SystemExit(result.returncode)
        """
    )


def build_bundle() -> None:
    if APP_PATH.exists():
        shutil.rmtree(APP_PATH)

    macos = APP_PATH / "Contents" / "MacOS"
    resources = APP_PATH / "Contents" / "Resources"
    macos.mkdir(parents=True)
    resources.mkdir(parents=True)

    shutil.copy2(DEBUG_BINARY, macos / "Minimail")
    shutil.copy2(CLI_ENGINE, macos / "email-cli-engine")
    wrapper = macos / "email-cli"
    wrapper.write_text(wrapper_source(), encoding="utf-8")
    wrapper.chmod(wrapper.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    with (ROOT / "Resources" / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    info["CFBundleIdentifier"] = "ai.paperfoot.minimail.qa"
    info["CFBundleDisplayName"] = "Minimail QA"
    info["CFBundleName"] = "Minimail QA"
    # An offline fixture must not register itself as a user's mailto handler.
    info.pop("CFBundleURLTypes", None)
    with (APP_PATH / "Contents" / "Info.plist").open("wb") as destination:
        plistlib.dump(info, destination, sort_keys=False)

    icon = ROOT / "Resources" / "AppIcon.icns"
    if icon.is_file():
        shutil.copy2(icon, resources / icon.name)

    run_checked(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(APP_PATH)], capture=True)


def validate_fixture() -> dict[str, int]:
    connection = sqlite3.connect(DB_PATH)
    try:
        checks = {
            "accounts": connection.execute("SELECT COUNT(*) FROM accounts").fetchone()[0],
            "messages": connection.execute("SELECT COUNT(*) FROM messages").fetchone()[0],
            "unread": connection.execute("SELECT COUNT(*) FROM messages WHERE is_read = 0").fetchone()[0],
            "starred": connection.execute("SELECT COUNT(*) FROM messages WHERE starred = 1").fetchone()[0],
            "sent": connection.execute("SELECT COUNT(*) FROM messages WHERE direction = 'sent'").fetchone()[0],
            "archived": connection.execute("SELECT COUNT(*) FROM messages WHERE archived = 1").fetchone()[0],
            "html": connection.execute("SELECT COUNT(*) FROM messages WHERE html_body IS NOT NULL").fetchone()[0],
            "drafts": connection.execute("SELECT COUNT(*) FROM drafts").fetchone()[0],
            "attachments": connection.execute("SELECT COUNT(*) FROM attachments").fetchone()[0],
        }
    finally:
        connection.close()

    expected_minimums = {
        "accounts": 2,
        "messages": 120,
        "unread": 1,
        "starred": 1,
        "sent": 1,
        "archived": 1,
        "html": 1,
        "drafts": 2,
        "attachments": 1,
    }
    for key, minimum in expected_minimums.items():
        if checks[key] < minimum:
            raise SystemExit(f"fixture validation failed: {key}={checks[key]}, expected at least {minimum}")

    helper = APP_PATH / "Contents" / "MacOS" / "email-cli"
    account_result = run_checked([str(helper), "account", "list", "--json"], capture=True)
    envelope = json.loads(account_result.stdout)
    if envelope.get("status") != "success" or len(envelope.get("data", [])) != 2:
        raise SystemExit("fixture helper could not read the two QA accounts")

    sync_result = run_checked([str(helper), "inbox", "sync", "--json"], capture=True)
    if json.loads(sync_result.stdout).get("status") != "success":
        raise SystemExit("fixture helper did not intercept inbox sync")

    send_result = subprocess.run(
        [str(helper), "send", "--to", "nobody@example.test", "--subject", "blocked", "--text", "blocked", "--json"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if send_result.returncode == 0 or "qa_fixture_offline" not in send_result.stderr:
        raise SystemExit("fixture helper did not block send")

    return checks


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--reset",
        action="store_true",
        help="delete and recreate the persistent QA database before building",
    )
    options = parser.parse_args()

    require_file(DEBUG_BINARY, "debug Minimail executable (run swift build first)")
    require_file(CLI_ENGINE, "release email-cli engine (run cargo build --release first)")
    require_file(ROOT / "Resources" / "Info.plist", "Info.plist")

    if options.reset:
        for suffix in ("", "-wal", "-shm"):
            candidate = Path(str(DB_PATH) + suffix)
            if candidate.exists():
                candidate.unlink()

    created = not DB_PATH.exists()
    if created:
        initialise_schema()
        seed_database()

    build_bundle()
    checks = validate_fixture()
    action = "created" if created else "preserved"
    print(f"Minimail QA bundle: {APP_PATH}")
    print(f"Fixture database ({action}): {DB_PATH}")
    print("Fixture accounts: " + ", ".join(account[0] for account in ACCOUNTS))
    print("Fixture drafts: Draft: launch notes with formatting; Draft: plain-text follow-up")
    print("Fixture reader case: Quarterly project review — long HTML & privacy test")
    print("Counts: " + ", ".join(f"{key}={value}" for key, value in checks.items()))
    print("Offline guards: sync/prefetch stubbed; send/reply/forward/network/outbox delivery blocked")


if __name__ == "__main__":
    main()
