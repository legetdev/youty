"""Exercise the real MCP client/server handshake without accessing a user vault."""
import asyncio
import os
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


def test_stdio_handshake_and_tool_call(seeded_db):
    """A clean subprocess must enumerate tools and answer a vault request."""
    db_path, _ = seeded_db

    async def run():
        """Connect using the same stdio transport as installed AI clients."""
        env = {**os.environ, "YOUTY_INDEX_DB": str(db_path), "HF_HUB_OFFLINE": "1"}
        params = StdioServerParameters(command=sys.executable, args=["-m", "youty_mcp.server"], env=env)
        async with stdio_client(params) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                tools = await session.list_tools()
                assert {tool.name for tool in tools.tools} == {"search", "get_transcript", "get_video", "view_frames", "list_videos", "find_similar", "search_frames"}
                result = await session.call_tool("list_videos", {"limit": 3})
                assert not result.isError
                assert "abc123" in str(result.content)

    asyncio.run(asyncio.wait_for(run(), timeout=30))
