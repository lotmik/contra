#!/usr/bin/env python3
"""Smoke-test the packaged add-on in an isolated Firefox profile."""

import json
import os
from pathlib import Path
import sys

try:
    from selenium import webdriver
    from selenium.webdriver.common.by import By
    from selenium.webdriver.common.keys import Keys
    from selenium.webdriver.firefox.options import Options
    from selenium.webdriver.support.ui import WebDriverWait
except ImportError as error:
    raise SystemExit(
        "Selenium is required: python3 -m pip install -r requirements-test.txt"
    ) from error


ROOT = Path(__file__).resolve().parent.parent
XPI = Path("/home/mik/projects/contra/dist/contra.xpi")
MANIFEST = ROOT / "manifest.json"


def main():
    if not XPI.is_file():
        raise SystemExit("Build the add-on first: bash scripts/build-xpi.sh")

    manifest = json.loads(MANIFEST.read_text())
    expected_id = manifest["browser_specific_settings"]["gecko"]["id"]
    expected_name = manifest["name"]

    # This only affects Firefox launched by this test. Chrome scope lets WebDriver
    # check that Firefox registered the toolbar action for the installed add-on.
    os.environ["MOZ_REMOTE_ALLOW_SYSTEM_ACCESS"] = "1"
    options = Options()
    options.add_argument("-headless")
    driver = webdriver.Firefox(options=options)
    try:
        installed_id = driver.install_addon(str(XPI), temporary=True)
        assert installed_id == expected_id, (
            f"Firefox installed {installed_id!r}, expected {expected_id!r}"
        )

        driver.set_context(driver.CONTEXT_CHROME)
        WebDriverWait(driver, 10).until(
            lambda browser: browser.find_element(By.ID, "unified-extensions-button")
        ).click()
        action = WebDriverWait(driver, 10).until(
            lambda browser: browser.find_element(
                By.CSS_SELECTOR,
                f'toolbarbutton[data-extensionid="{expected_id}"][id$="-BAP"]',
            )
        )
        assert expected_name in action.text, "The installed add-on has no visible toolbar action"
        action.click()
        popup_url = WebDriverWait(driver, 10).until(
            lambda browser: next(
                (
                    url for url in browser.execute_script(
                        "return [...document.querySelectorAll('browser.webextension-popup-browser')]"
                        ".map(element => element.currentURI?.spec)"
                    )
                    if url and url.endswith("/popup.html")
                ),
                None,
            )
        )

        driver.set_context(driver.CONTEXT_CONTENT)
        driver.get(popup_url)
        driver.find_element(By.ID, "settings-summary").click()
        startup_group = driver.find_element(By.ID, "startup-settings-group")
        assert startup_group.is_displayed(), "Startup setting is not visible in the popup"
        assert startup_group.rect["height"] < 90, "Startup setting is too tall"
        off_option = driver.find_element(
            By.CSS_SELECTOR, '#startup-mode-segment [data-value="off"]'
        )
        block_option = driver.find_element(
            By.CSS_SELECTOR, '#startup-mode-segment [data-value="block"]'
        )
        allow_option = driver.find_element(
            By.CSS_SELECTOR, '#startup-mode-segment [data-value="allow"]'
        )
        assert block_option.get_attribute("aria-checked") == "true"

        allow_option.click()
        WebDriverWait(driver, 5).until(
            lambda browser: allow_option.get_attribute("aria-checked") == "true"
        )
        WebDriverWait(driver, 5).until(
            lambda browser: browser.execute_async_script(
                "browser.storage.local.get('startupMode')"
                ".then(value => arguments[arguments.length - 1](value.startupMode))"
            ) == "allow"
        )

        off_option.click()
        assert off_option.get_attribute("aria-checked") == "true"
        WebDriverWait(driver, 5).until(
            lambda browser: browser.execute_async_script(
                "browser.storage.local.get('autoTurnOn')"
                ".then(value => arguments[arguments.length - 1](value.autoTurnOn))"
            ) is False
        )

        driver.refresh()
        driver.find_element(By.ID, "settings-summary").click()
        assert driver.find_element(
            By.CSS_SELECTOR, '#startup-mode-segment [data-value="off"]'
        ).get_attribute("aria-checked") == "true"
        allow_option = driver.find_element(
            By.CSS_SELECTOR, '#startup-mode-segment [data-value="allow"]'
        )
        allow_option.click()
        assert driver.find_element(
            By.CSS_SELECTOR, '#startup-mode-segment [data-value="allow"]'
        ).get_attribute("aria-checked") == "true"
        block_option = driver.find_element(
            By.CSS_SELECTOR, '#startup-mode-segment [data-value="block"]'
        )
        allow_option.send_keys(Keys.ARROW_LEFT)
        WebDriverWait(driver, 5).until(
            lambda browser: block_option.get_attribute("aria-checked") == "true"
        )
        print(
            f"Firefox {driver.capabilities['browserVersion']}: XPI installed; "
            "compact startup menu, all three choices, keyboard control, and persistence verified"
        )
    finally:
        driver.quit()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Firefox smoke test failed: {error}", file=sys.stderr)
        raise
