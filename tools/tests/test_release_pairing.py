"""The frozen-release WebSocket probe uses the same pairing contract as a browser."""

import sys
import unittest
from pathlib import Path

from aiohttp.test_utils import TestServer

from hub.regina_hub.hub import Hub
from hub.regina_hub.sources.web import WebSource

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from smoke_release import check_websocket  # noqa: E402


class ReleasePairingTests(unittest.IsolatedAsyncioTestCase):
    async def test_release_probe_obtains_token_and_authenticates(self):
        hub = Hub()
        source = WebSource(hub)
        async with TestServer(source.app) as server:
            await check_websocket(str(server.make_url("/ws")))
        self.assertEqual(len(hub.controllers), 1)
        controller = next(iter(hub.controllers.values()))
        self.assertEqual(controller.kind, "sim")
        self.assertFalse(controller.connected)
