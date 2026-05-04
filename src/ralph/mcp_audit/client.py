"""Thin async stdio JSON-RPC client for an MCP server.

Connects via subprocess + line-oriented JSON-RPC, performs initialize +
notifications/initialized handshake, then exposes list_tools / call_tool.
"""
from __future__ import annotations

import asyncio
import json
import logging
from dataclasses import dataclass
from typing import Any

log = logging.getLogger(__name__)


class McpClientError(RuntimeError):
    pass


@dataclass(slots=True)
class ToolDescriptor:
    name: str
    description: str
    input_schema: dict[str, Any]


class McpStdioClient:
    """Speaks JSON-RPC line protocol with a child MCP process over stdio."""

    def __init__(self, cmd: list[str], *, env: dict[str, str] | None = None):
        self.cmd = cmd
        self.env = env
        self._proc: asyncio.subprocess.Process | None = None
        self._next_id = 1

    async def start(self) -> None:
        log.debug("spawning MCP server: %s", " ".join(self.cmd))
        self._proc = await asyncio.create_subprocess_exec(
            *self.cmd,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=self.env,
        )
        await self._handshake()

    async def stop(self) -> None:
        if not self._proc:
            return
        try:
            self._proc.terminate()
            await asyncio.wait_for(self._proc.wait(), timeout=5)
        except (TimeoutError, ProcessLookupError):
            self._proc.kill()
        self._proc = None

    async def _handshake(self) -> None:
        await self._send_request(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "mcp-ralph-audit", "version": "0.1.0"},
            },
        )
        await self._send_notification("notifications/initialized", {})

    async def list_tools(self) -> list[ToolDescriptor]:
        result = await self._send_request("tools/list", {})
        tools_raw = result.get("tools", [])
        return [
            ToolDescriptor(
                name=t["name"],
                description=t.get("description", ""),
                input_schema=t.get("inputSchema", {}),
            )
            for t in tools_raw
        ]

    async def call_tool(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        return await self._send_request("tools/call", {"name": name, "arguments": arguments})

    async def _send_request(self, method: str, params: dict[str, Any], *, timeout_s: float = 30.0) -> dict[str, Any]:
        if not self._proc or not self._proc.stdin or not self._proc.stdout:
            raise McpClientError("client not started")

        request_id = self._next_id
        self._next_id += 1
        msg = json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        self._proc.stdin.write((msg + "\n").encode("utf-8"))
        await self._proc.stdin.drain()

        async def read_until_response() -> dict[str, Any]:
            assert self._proc and self._proc.stdout
            while True:
                line = await self._proc.stdout.readline()
                if not line:
                    raise McpClientError("MCP server closed stdout without responding")
                try:
                    payload = json.loads(line.decode("utf-8"))
                except json.JSONDecodeError:
                    continue
                if payload.get("id") == request_id:
                    if "error" in payload:
                        raise McpClientError(f"MCP error: {payload['error']}")
                    return payload.get("result", {})

        return await asyncio.wait_for(read_until_response(), timeout=timeout_s)

    async def _send_notification(self, method: str, params: dict[str, Any]) -> None:
        if not self._proc or not self._proc.stdin:
            raise McpClientError("client not started")
        msg = json.dumps({"jsonrpc": "2.0", "method": method, "params": params})
        self._proc.stdin.write((msg + "\n").encode("utf-8"))
        await self._proc.stdin.drain()
