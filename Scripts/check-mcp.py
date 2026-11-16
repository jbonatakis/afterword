#!/usr/bin/env python3
"""Exercise the actual stdio executable using the official MCP Python client.

Run: uv run --with mcp==1.28.1 Scripts/check-mcp.py /path/to/AfterwordMCP
Uses synthetic audio and temporary access settings, never the user's library.
"""
import asyncio
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import wave

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def check(executable):
    with tempfile.TemporaryDirectory(prefix="afterword-mcp-") as temporary:
        base = Path(temporary).resolve()
        root, state = base / "calls", base / "state"
        root.mkdir(); state.mkdir()
        audio = root / "Fixture.wav"
        with wave.open(str(audio), "wb") as output:
            output.setparams((1, 2, 16000, 1600, "NONE", "not compressed"))
            output.writeframes(b"\x00\x00" * 1600)
        original = hashlib.sha256(audio.read_bytes()).hexdigest()
        transcript_folder = root / "Transcripts" / "fixture"
        transcript_folder.mkdir(parents=True)
        transcript_text = 'Café decision: keep the "current" plan.\nSecond line.'
        transcript_file = transcript_folder / "Transcript.json"
        transcript_file.write_text(json.dumps({
            "version": 2, "recording": "Fixture", "createdAt": "2026-11-15T12:00:00Z",
            "modelID": "fixture", "modelName": "Fixture", "modelSHA256": "fixture",
            "engine": "fixture", "language": "en", "sources": {"mixed": "Fixture.wav"},
            "segments": [{"source": "mixed", "start": 0, "end": 0.1, "text": transcript_text, "timing": "segment"}]
        }))
        transcript_original = transcript_file.read_bytes()
        access = state / "Access.json"
        def settings(enabled, writes=False):
            pending = state / "pending.json"
            pending.write_text(json.dumps({"version": 1, "enabled": enabled, "folders": [str(root)], "allowSummaryWrites": writes}))
            pending.replace(access)
        settings(True)
        parameters = StdioServerParameters(command=str(executable), args=["--state-directory", str(state)])
        async with stdio_client(parameters) as (read, write):
            async with ClientSession(read, write) as session:
                initialized = await session.initialize()
                assert initialized.serverInfo.name == "afterword"
                tools = await session.list_tools()
                assert {tool.name for tool in tools.tools} == {"list_calls", "search_transcripts", "get_call", "get_transcript", "get_changes", "save_call_summary"}
                assert all(tool.annotations.readOnlyHint == (tool.name != "save_call_summary") for tool in tools.tools)
                result = await session.call_tool("list_calls", {})
                assert not result.isError
                calls = result.structuredContent["items"]
                assert len(calls) == 1 and calls[0]["title"] == "Fixture"
                call_id = calls[0]["call_id"]
                info = await session.call_tool("get_call", {"call_id": call_id})
                assert not info.isError and len(info.structuredContent["versions"]) == 1
                transcript = await session.call_tool("get_transcript", {"call_id": call_id})
                assert not transcript.isError and transcript.structuredContent["items"][0]["text"] == transcript_text
                search = await session.call_tool("search_transcripts", {"query": "CAFE"})
                assert not search.isError and search.structuredContent["total"] == 1
                baseline = await session.call_tool("get_changes", {})
                cursor = baseline.structuredContent["cursor"]
                same = await session.call_tool("get_changes", {"cursor": cursor})
                assert same.structuredContent["changes"] == []
                # A write must be explicitly enabled and use a current call revision.
                summary_args = {"call_id": call_id, "expected_revision": info.structuredContent["revision"],
                                "source_version_id": info.structuredContent["versions"][0]["version_id"],
                                "markdown": "## Summary\n\nCobalt follow-up — keep the café plan. " + "é" * 33000}
                denied = await session.call_tool("save_call_summary", summary_args)
                assert denied.isError
                settings(True, writes=True)
                saved = await session.call_tool("save_call_summary", summary_args)
                assert not saved.isError, saved
                assert saved.structuredContent["summary"]["markdown"] == summary_args["markdown"]
                first_summary = saved.structuredContent["summary"]["revision_id"]
                conflict = await session.call_tool("save_call_summary", summary_args)
                assert conflict.isError
                summary_search = await session.call_tool("list_calls", {"query": "cobal", "mode": "keyword"})
                assert summary_search.structuredContent["items"][0]["match_source"] == "summary"
                spoken = await session.call_tool("search_transcripts", {"query": "cobalt", "mode": "keyword"})
                assert spoken.structuredContent["total"] == 0
                changes = await session.call_tool("get_changes", {"cursor": cursor})
                assert changes.structuredContent["changes"][0]["change"] == "updated"
                summary_args.update(expected_revision=saved.structuredContent["call"]["revision"], markdown="Revised summary")
                edited = await session.call_tool("save_call_summary", summary_args)
                assert not edited.isError
                old = await session.call_tool("get_call", {"call_id": call_id, "summary_revision_id": first_summary})
                assert len(old.structuredContent["summary_versions"]) == 2
                assert old.structuredContent["summary"]["markdown"].startswith("## Summary")
                summary_args["expected_revision"] = edited.structuredContent["call"]["revision"]
                settings(True)
                revoked_write = await session.call_tool("save_call_summary", summary_args)
                assert revoked_write.isError
                settings(False)
                revoked = await session.call_tool("list_calls", {})
                assert revoked.isError and "disabled" in revoked.content[0].text
                settings(True)
                assert hashlib.sha256(audio.read_bytes()).hexdigest() == original
                assert transcript_file.read_bytes() == transcript_original
                audio.unlink()
                removed = await session.call_tool("get_changes", {"cursor": cursor})
                assert removed.structuredContent["changes"] == [{"call_id": call_id, "change": "removed"}]
        # Separate client process reuses the same checkpoint.
        async with stdio_client(parameters) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                removed_again = await session.call_tool("get_changes", {"cursor": cursor})
                assert removed_again.structuredContent["changes"][0]["change"] == "removed"

        # Framing: requests split into individual bytes, coalesced notifications,
        # malformed JSON, and a clean EOF must not pollute stdout or hang.
        child = subprocess.Popen([str(executable), "--state-directory", str(state)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        request = {"jsonrpc": "2.0", "id": "unicode-é", "method": "ping"}
        for byte in (json.dumps(request, ensure_ascii=False) + "\n").encode():
            child.stdin.write(bytes([byte])); child.stdin.flush()
        child.stdin.write(b'bad json\n{"jsonrpc":"2.0","method":"notifications/cancelled"}\n')
        child.stdin.close()
        child.stdin = None
        try:
            stdout, _ = child.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill(); child.communicate(); raise
        responses = [json.loads(line) for line in stdout.splitlines()]
        assert child.returncode == 0
        assert responses[0]["id"] == "unicode-é" and responses[0]["result"] == {}
        assert responses[1]["error"]["code"] == -32700 and len(responses) == 2
        print("PASS official MCP client initialization, discovery, summary writes/history/conflicts, checkpoint restart, live revocation, framing, and EOF")


if __name__ == "__main__":
    asyncio.run(asyncio.wait_for(check(Path(sys.argv[1]).resolve()), timeout=30))
