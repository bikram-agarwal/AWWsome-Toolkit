#!/usr/bin/env python3
"""Merge GitHub Release Feeds

Auto-discovers starred repos and star list categories from GitHub,
fetches release feeds, and generates combined + per-category Atom feeds.

Output: _site/feeds/*.atom + _site/index.html
"""

import copy
import html
import json
import os
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from http.client import IncompleteRead
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from xml.etree import ElementTree as ET

GITHUB_USERNAME = "bikram-agarwal"
PAGES_BASE_URL = f"https://{GITHUB_USERNAME}.github.io/AWWsome-Toolkit/feeds"
ATOM_NS = "http://www.w3.org/2005/Atom"
MAX_ENTRIES_PER_CATEGORY = 200
MAX_ENTRIES_ALL = 300
FEED_FETCH_WORKERS = 20
RELEASES_PAGE_SIZE = 50
RELEASES_PAGES_PER_REPO = 1
GITHUB_API_RETRIES = 3
GITHUB_API_RETRY_DELAY_SEC = 2
RETRYABLE_HTTP_CODES = (429, 500, 502, 503, 504)
OUTPUT_DIR = Path("_site/feeds")

ET.register_namespace("", ATOM_NS)


def github_api_get(url):
    """Fetch a GitHub API endpoint, using GITHUB_TOKEN for higher rate limits.
    Retries on transient errors: IncompleteRead, connection/timeout errors,
    and HTTP 429/5xx.
    """
    headers = {
        "Accept": "application/vnd.github.v3.html+json",
        "User-Agent": "merge-release-feeds",
    }
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"token {token}"
    last_error = None
    for attempt in range(GITHUB_API_RETRIES):
        try:
            with urlopen(Request(url, headers=headers), timeout=30) as response:
                return json.loads(response.read().decode())
        except HTTPError as err:
            last_error = err
            if err.code in RETRYABLE_HTTP_CODES and attempt < GITHUB_API_RETRIES - 1:
                time.sleep(GITHUB_API_RETRY_DELAY_SEC)
            else:
                raise last_error
        except (IncompleteRead, URLError, ConnectionError, TimeoutError) as err:
            last_error = err
            if attempt < GITHUB_API_RETRIES - 1:
                time.sleep(GITHUB_API_RETRY_DELAY_SEC)
            else:
                raise last_error


def web_get(url):
    """Fetch a URL and return the response body as text."""
    with urlopen(
        Request(url, headers={"User-Agent": "merge-release-feeds"}), timeout=30
    ) as response:
        return response.read().decode()


def fetch_starred_repos():
    """Fetch all starred repo full_names via the GitHub API (handles pagination)."""
    repos = []
    page = 1
    while True:
        api_url = (
            f"https://api.github.com/users/{GITHUB_USERNAME}"
            f"/starred?per_page=100&page={page}"
        )
        print(f"  Fetching starred repos (page {page})...")
        batch = github_api_get(api_url)
        if not batch:
            break
        repos.extend(entry["full_name"] for entry in batch)
        if len(batch) < 100:
            break
        page += 1
    return repos


def discover_lists_and_repos(starred_set):
    """Discover star lists from the profile page, then fetch each list page
    to determine which starred repos belong to which category.

    Returns dict: {slug: {"name": display_name, "repos": [repo, ...]}}
    """
    print("  Fetching stars page to discover lists...")
    stars_html = web_get(f"https://github.com/{GITHUB_USERNAME}?tab=stars")

    slug_pattern = rf"/stars/{re.escape(GITHUB_USERNAME)}/lists/([a-z0-9_-]+)"
    slugs = list(dict.fromkeys(re.findall(slug_pattern, stars_html)))

    categories = {}
    for slug in slugs:
        display_name = slug.replace("-", " ").title()
        name_pattern = (
            rf'href="/stars/{re.escape(GITHUB_USERNAME)}/lists/{re.escape(slug)}'
            rf'"[^>]*>\s*([^<]+)'
        )
        name_match = re.search(name_pattern, stars_html)
        if name_match and name_match.group(1).strip():
            display_name = name_match.group(1).strip()

        print(f"  Fetching list '{display_name}'...")
        repos_in_list = set()
        page_num = 1
        while True:
            list_url = (
                f"https://github.com/stars/{GITHUB_USERNAME}"
                f"/lists/{slug}?page={page_num}"
            )
            try:
                list_html = web_get(list_url)
            except (HTTPError, URLError):
                break

            repo_hrefs = re.findall(
                r'href="/([A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+)"', list_html
            )
            new_repos = {href for href in repo_hrefs if href in starred_set}
            new_repos -= repos_in_list
            if not new_repos:
                break

            repos_in_list.update(new_repos)
            if f"page={page_num + 1}" not in list_html:
                break
            page_num += 1

        categories[slug] = {"name": display_name, "repos": sorted(repos_in_list)}
        print(f"    {len(repos_in_list)} repos")

    return categories


def fetch_releases_api(repo):
    """Fetch recent releases for a repo via GitHub API (releases only, no tag-only).
    Only fetches the first N pages (newest first) to avoid scanning hundreds of
    releases per repo. Returns (repo, list of release dicts).
    """
    releases = []
    try:
        for page in range(1, RELEASES_PAGES_PER_REPO + 1):
            api_url = (
                f"https://api.github.com/repos/{repo}/releases"
                f"?per_page={RELEASES_PAGE_SIZE}&page={page}"
            )
            batch = github_api_get(api_url)
            if not batch:
                break
            releases.extend(batch)
            if len(batch) < RELEASES_PAGE_SIZE:
                break
    except (
        HTTPError,
        URLError,
        IncompleteRead,
        ConnectionError,
        TimeoutError,
    ) as err:
        print(f"    Warning: {repo} - {err}")
        return repo, []
    return repo, releases


def release_to_atom_entry(repo, release):
    """Build one Atom <entry> Element from a GitHub API release dict."""
    entry = ET.Element(f"{{{ATOM_NS}}}entry")
    tag_name = release.get("tag_name", "")
    html_url = release.get("html_url", f"https://github.com/{repo}/releases/tag/{tag_name}")
    node_id = release.get("node_id", "")
    entry_id = f"tag:github.com,2008:Repository/{node_id}/{tag_name}" if node_id else html_url
    ET.SubElement(entry, f"{{{ATOM_NS}}}id").text = entry_id
    updated = release.get("published_at") or release.get("created_at", "")
    if updated:
        ET.SubElement(entry, f"{{{ATOM_NS}}}updated").text = updated
    link = ET.SubElement(entry, f"{{{ATOM_NS}}}link")
    link.set("rel", "alternate")
    link.set("type", "text/html")
    link.set("href", html_url)
    title = release.get("name") or tag_name
    ET.SubElement(entry, f"{{{ATOM_NS}}}title").text = f"{repo}: {title}"
    body_html = release.get("body_html") or ""
    if not body_html and release.get("body"):
        body_html = f"<p>{html.escape(release['body'])}</p>"
    content_elem = ET.SubElement(entry, f"{{{ATOM_NS}}}content")
    content_elem.set("type", "html")
    content_elem.text = body_html
    author = ET.SubElement(entry, f"{{{ATOM_NS}}}author")
    author_login = "unknown"
    if release.get("author") and isinstance(release["author"], dict):
        author_login = release["author"].get("login", author_login)
    ET.SubElement(author, f"{{{ATOM_NS}}}name").text = author_login
    return entry


def releases_to_entries(repo, releases):
    """Convert API release list to Atom entry Elements with repo-prefixed titles."""
    return [release_to_atom_entry(repo, release) for release in releases]


def entry_updated_key(entry):
    """Sort key: extract <updated> text from an Atom entry."""
    updated_elem = entry.find(f"{{{ATOM_NS}}}updated")
    if updated_elem is not None and updated_elem.text:
        return updated_elem.text
    return ""


def build_atom_feed(title, self_url, entries):
    """Build a complete Atom feed XML string from entry Elements."""
    feed = ET.Element(f"{{{ATOM_NS}}}feed")
    ET.SubElement(feed, f"{{{ATOM_NS}}}title").text = title
    ET.SubElement(feed, f"{{{ATOM_NS}}}id").text = self_url
    self_link = ET.SubElement(feed, f"{{{ATOM_NS}}}link")
    self_link.set("rel", "self")
    self_link.set("href", self_url)
    ET.SubElement(feed, f"{{{ATOM_NS}}}updated").text = datetime.now(
        timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ")
    author = ET.SubElement(feed, f"{{{ATOM_NS}}}author")
    ET.SubElement(author, f"{{{ATOM_NS}}}name").text = GITHUB_USERNAME

    for entry in entries:
        feed.append(copy.deepcopy(entry))

    ET.indent(feed, space="  ")
    return '<?xml version="1.0" encoding="UTF-8"?>\n' + ET.tostring(
        feed, encoding="unicode"
    )


def write_feed(filename, title, entries, max_entries):
    """Sort entries by date, cap at max_entries, and write an Atom feed to disk."""
    sorted_entries = sorted(entries, key=entry_updated_key, reverse=True)[:max_entries]
    self_url = f"{PAGES_BASE_URL}/{filename}"
    xml_output = build_atom_feed(title, self_url, sorted_entries)
    (OUTPUT_DIR / filename).write_text(xml_output, encoding="utf-8")
    return len(sorted_entries)


def generate_index_html(feed_info):
    """Generate _site/index.html listing all available feeds."""
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    rows = "\n".join(
        f'    <li><a href="feeds/{fname}">{label}</a>'
        f" ({count} repos, {entries} entries)</li>"
        for fname, label, count, entries in feed_info
    )
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>GitHub Stars Release Feeds</title>
  <style>
    body {{ font-family: system-ui, sans-serif; max-width: 600px; margin: 2rem auto; padding: 0 1rem; }}
    a {{ color: #0969da; }}
    li {{ margin: 0.5rem 0; }}
  </style>
</head>
<body>
  <h1>GitHub Stars Release Feeds</h1>
  <p>Auto-generated release feeds for
    <a href="https://github.com/{GITHUB_USERNAME}?tab=stars">{GITHUB_USERNAME}'s starred repos</a>.
  </p>
  <ul>
{rows}
  </ul>
  <p><small>Last updated: {timestamp}</small></p>
</body>
</html>"""


def main():
    print("=== Step 1: Discover starred repos ===")
    starred_repos = fetch_starred_repos()
    if not starred_repos:
        print("Error: No starred repos found.")
        sys.exit(1)
    print(f"  Total: {len(starred_repos)} starred repos\n")
    starred_set = set(starred_repos)

    print("=== Step 2: Discover star list categories ===")
    categories = discover_lists_and_repos(starred_set)

    categorized_repos = set()
    for info in categories.values():
        categorized_repos.update(info["repos"])

    uncategorized_repos = [repo for repo in starred_repos if repo not in categorized_repos]
    if uncategorized_repos:
        categories["uncategorized"] = {"name": "Uncategorized", "repos": uncategorized_repos}
    print(f"  {len(uncategorized_repos)} uncategorized repos\n")

    print(f"=== Step 3: Fetch releases via API ({len(starred_repos)} repos) ===")
    repo_entries = {}
    with ThreadPoolExecutor(max_workers=FEED_FETCH_WORKERS) as pool:
        futures = {
            pool.submit(fetch_releases_api, repo): repo for repo in starred_repos
        }
        for future in as_completed(futures):
            repo, releases = future.result()
            repo_entries[repo] = releases_to_entries(repo, releases)

    total_entries = sum(len(entry_list) for entry_list in repo_entries.values())
    print(f"  Parsed {total_entries} entries total\n")

    print("=== Step 4: Generate feeds ===")
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    feed_info = []

    all_entries = [entry for entry_list in repo_entries.values() for entry in entry_list]
    entry_count = write_feed(
        "all.atom", "GitHub Stars - All Releases", all_entries, MAX_ENTRIES_ALL
    )
    feed_info.append(("all.atom", "All Releases", len(starred_repos), entry_count))
    print(f"  all.atom: {entry_count} entries from {len(starred_repos)} repos")

    for slug in sorted(categories):
        info = categories[slug]
        cat_entries = [
            entry
            for repo in info["repos"]
            for entry in repo_entries.get(repo, [])
        ]
        entry_count = write_feed(
            f"{slug}.atom",
            f"GitHub Stars - {info['name']}",
            cat_entries,
            MAX_ENTRIES_PER_CATEGORY,
        )
        feed_info.append(
            (f"{slug}.atom", info["name"], len(info["repos"]), entry_count)
        )
        print(f"  {slug}.atom: {entry_count} entries from {len(info['repos'])} repos")

    Path("_site/index.html").write_text(
        generate_index_html(feed_info), encoding="utf-8"
    )
    print(f"\n  index.html generated")
    print(f"\nDone! {len(feed_info)} feeds written to {OUTPUT_DIR}/")


if __name__ == "__main__":
    main()
