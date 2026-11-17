from html.parser import HTMLParser
import importlib.util
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]
SITE = ROOT / "Website"
ORIGIN = "https://mac-wombat.pages.dev"
GITHUB = "https://github.com/arnefranz-del/mac-wombat"


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__()
        self.elements = []
        self.feed(path.read_text(encoding="utf-8"))

    def handle_starttag(self, tag, attrs):
        self.elements.append((tag, dict(attrs)))

    def tags(self, name):
        return [attributes for tag, attributes in self.elements if tag == name]


class WebsiteTests(unittest.TestCase):
    def test_localized_pages_have_reciprocal_search_metadata_and_build_links(self):
        for lang, route, readme, build, legal_paths in (
            ("de", "/", "README.de.md", "lokal-bauen", ("/impressum/", "/datenschutz/")),
            ("en", "/en/", "README.md", "build-locally", ("/en/legal/", "/en/privacy/")),
        ):
            with self.subTest(lang=lang):
                page = Page(SITE / route.lstrip("/") / "index.html")
                self.assertEqual(page.tags("html")[0]["lang"], lang)
                self.assertEqual(len(page.tags("h1")), 1)
                links = page.tags("link")
                self.assertEqual([link["href"] for link in links if link["rel"] == "canonical"], [ORIGIN + route])
                self.assertEqual(
                    {link["hreflang"]: link["href"] for link in links if link["rel"] == "alternate"},
                    {"de": ORIGIN + "/", "en": ORIGIN + "/en/", "x-default": ORIGIN + "/"},
                )
                metadata = {item["property"]: item["content"] for item in page.tags("meta") if "property" in item}
                self.assertEqual(metadata["og:url"], ORIGIN + route)
                self.assertTrue((SITE / urlsplit(metadata["og:image"]).path.lstrip("/")).is_file())
                self.assertTrue(metadata["og:image:alt"])
                anchors = {anchor["href"] for anchor in page.tags("a")}
                self.assertIn(GITHUB + f"/blob/main/{readme}#{build}", anchors)
                self.assertIn("## " + build.replace("-", " ").capitalize(), (ROOT / readme).read_text(encoding="utf-8"))
                for legal_path in legal_paths:
                    self.assertIn(ORIGIN + legal_path, anchors)

    def test_static_pages_resolve_their_own_assets_and_sections(self):
        for route in ("index.html", "en/index.html", "404.html"):
            with self.subTest(route=route):
                page = Page(SITE / route)
                self.assertFalse(page.tags("script"))
                ids = [attrs["id"] for _, attrs in page.elements if "id" in attrs]
                self.assertEqual(len(ids), len(set(ids)))
                for image in page.tags("img"):
                    self.assertIn("alt", image)
                    self.assertGreater(int(image["width"]), 0)
                    self.assertGreater(int(image["height"]), 0)
                    for entry in image.get("srcset", "").split(","):
                        if entry.strip():
                            self.assertTrue((SITE / entry.split()[0].lstrip("/")).is_file())
                for _, attributes in page.elements:
                    url = attributes.get("src") or attributes.get("href", "")
                    if url.startswith("/") and not url.startswith("//"):
                        target = SITE / url.lstrip("/")
                        self.assertTrue((target / "index.html" if url.endswith("/") else target).is_file(), url)
                    if url.startswith("#"):
                        self.assertIn(url[1:], ids)
                for tag in ("script", "iframe", "form"):
                    self.assertEqual(page.tags(tag), [])

    def test_staging_requires_all_legal_pages_and_preserves_their_bytes(self):
        spec = importlib.util.spec_from_file_location("stage_website", ROOT / "Scripts" / "stage-website.py")
        staging = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(staging)
        with TemporaryDirectory() as temp:
            legal, output = Path(temp) / "legal", Path(temp) / "output"
            with self.assertRaisesRegex(ValueError, "Missing or empty operator page"):
                staging.stage(SITE, legal, output)
            self.assertFalse(output.exists())
            for page in staging.LEGAL_PAGES:
                source = legal / page
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text("<!doctype html><title>Synthetic operator page</title>", encoding="utf-8")
            staging.stage(SITE, legal, output)
            self.assertEqual((output / "_headers").read_bytes(), (SITE / "_headers").read_bytes())
            for page in staging.LEGAL_PAGES:
                self.assertEqual((output / page).read_bytes(), (legal / page).read_bytes())
            with self.assertRaisesRegex(ValueError, "already exists"):
                staging.stage(SITE, legal, output)
