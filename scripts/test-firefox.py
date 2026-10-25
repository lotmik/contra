#!/usr/bin/env python3
"""Smoke-test the packaged add-on in an isolated Firefox profile."""

import json
import os
from pathlib import Path
import sys
import time

try:
    from selenium import webdriver
    from selenium.webdriver.common.by import By
    from selenium.webdriver.common.keys import Keys
    from selenium.webdriver.common.action_chains import ActionChains
    from selenium.common.exceptions import StaleElementReferenceException
    from selenium.webdriver.firefox.options import Options
    from selenium.webdriver.support.ui import WebDriverWait
except ImportError as error:
    raise SystemExit(
        "Selenium is required: python3 -m pip install -r requirements-test.txt"
    ) from error


ROOT = Path(__file__).resolve().parent.parent
XPI = Path("/home/mik/projects/contra/dist/contra.xpi")
MANIFEST = ROOT / "manifest.json"


def assert_settings_layout(driver, active_section, allow_area_scroll=False):
    layout = driver.execute_script(
        "const root = document.getElementById('popup-root');"
        "const area = document.getElementById('settings-area');"
        "return {rootHeight: root.getBoundingClientRect().height,"
        "bottomSpace: root.getBoundingClientRect().bottom - area.getBoundingClientRect().bottom,"
        "areaHeight: area.clientHeight, areaContentHeight: area.scrollHeight,"
        "websiteOpen: document.getElementById('website-settings-dropdown').open,"
        "phraseOpen: document.getElementById('unlock-phrase-setting-dropdown').open}"
    )
    assert layout["rootHeight"] <= 600, f"Popup exceeds Firefox's height limit: {layout}"
    assert layout["bottomSpace"] <= 10, f"Unused space below settings: {layout}"
    if not allow_area_scroll:
        assert layout["areaContentHeight"] <= layout["areaHeight"], (
            f"Settings require scrolling: {layout}"
        )
    assert layout["websiteOpen"] == (active_section == "website"), layout
    assert layout["phraseOpen"] == (active_section == "phrase"), layout


def popup_geometry(driver):
    return driver.execute_script(
        "const ids = ['popup-root', 'header-title', 'power-toggle-label', "
        "'settings-summary', 'settings-area', 'website-settings-dropdown', "
        "'site-row-scroll', 'site-add-row', 'unlock-mode-settings-stack', "
        "'unlock-phrase-setting-dropdown', 'unlock-phrase-setting'];"
        "return Object.fromEntries(ids.map(id => {"
        "const element = document.getElementById(id);"
        "const rect = element.getBoundingClientRect();"
        "return [id, {top: rect.top, bottom: rect.bottom, height: rect.height}]}))"
    )


def save_white_debug_screenshot(driver, destination):
    driver.execute_script(
        "const style = document.createElement('style');"
        "style.id = 'contra-visual-debug';"
        "style.textContent = 'html, body { background: white !important; }';"
        "document.head.append(style)"
    )
    try:
        driver.save_screenshot(str(destination))
    finally:
        driver.execute_script("document.getElementById('contra-visual-debug').remove()")


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
        # Firefox may replace its popup browser immediately after the panel opens.
        # Locate it afresh before the click and retry only if that node went stale.
        time.sleep(0.3)

        def find_popup_browser(browser):
            return next(
                (
                    element for element in browser.find_elements(
                        By.CSS_SELECTOR, "browser.webextension-popup-browser"
                    )
                    if browser.execute_script(
                        "return arguments[0].currentURI?.spec.endsWith('/popup.html')", element
                    )
                ),
                None,
            )

        popup_browser = WebDriverWait(
            driver, 10, ignored_exceptions=(StaleElementReferenceException,)
        ).until(find_popup_browser)
        popup_url = driver.execute_script("return arguments[0].currentURI.spec", popup_browser)
        for attempt in range(3):
            popup_browser = find_popup_browser(driver)
            try:
                ActionChains(driver).move_to_element_with_offset(
                    popup_browser, 0, 50
                ).click().perform()
                break
            except StaleElementReferenceException:
                if attempt == 2:
                    raise
        native_popup_height = WebDriverWait(driver, 5).until(
            lambda browser: (
                height if 161 < (height := find_popup_browser(browser).rect["height"]) <= 600
                else False
            )
        )

        driver.set_context(driver.CONTEXT_CONTENT)
        driver.set_window_size(470, 780)
        driver.get(popup_url)
        screenshot_dir = os.environ.get("CONTRA_SCREENSHOTS_DIR")
        if screenshot_dir:
            Path(screenshot_dir).mkdir(parents=True, exist_ok=True)
            save_white_debug_screenshot(
                driver, Path(screenshot_dir) / "settings-collapsed-white-backdrop.png"
            )
        collapsed_geometry = popup_geometry(driver)
        driver.find_element(By.ID, "settings-summary").click()
        expanded_geometry = popup_geometry(driver)
        assert expanded_geometry["popup-root"]["height"] < 600, expanded_geometry
        assert abs(native_popup_height - expanded_geometry["popup-root"]["height"]) <= 3, (
            f"Native popup and extension page differ: {native_popup_height}, {expanded_geometry}"
        )
        for anchor in ("header-title", "power-toggle-label", "settings-summary"):
            assert abs(
                collapsed_geometry[anchor]["top"] - expanded_geometry[anchor]["top"]
            ) < 0.5, f"{anchor} moved when settings opened: {collapsed_geometry} -> {expanded_geometry}"
        if os.environ.get("CONTRA_LAYOUT_DIAGNOSTICS"):
            print("Native toolbar popup height:", native_popup_height)
            print("Collapsed geometry:", collapsed_geometry)
            print("Expanded geometry:", expanded_geometry)
        assert_settings_layout(driver, "website")
        empty_sites = driver.execute_script(
            "const list = document.getElementById('site-row-scroll');"
            "return [list.children.length, list.getBoundingClientRect().height]"
        )
        assert empty_sites == [0, 0], f"Empty websites reserve space: {empty_sites}"
        if screenshot_dir:
            save_white_debug_screenshot(
                driver, Path(screenshot_dir) / "websites-empty-white-backdrop.png"
            )
        driver.find_element(By.ID, "unlock-phrase-setting-summary").click()
        assert_settings_layout(driver, "phrase")
        if screenshot_dir:
            save_white_debug_screenshot(
                driver, Path(screenshot_dir) / "pause-phrase-white-backdrop.png"
            )
        driver.find_element(By.ID, "website-settings-summary").click()
        assert_settings_layout(driver, "website")
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
        assert_settings_layout(driver, "website")
        startup_surface = driver.execute_script(
            "const style = getComputedStyle(document.getElementById('startup-settings-group'));"
            "return [style.backgroundColor, style.borderTopWidth]"
        )
        assert startup_surface == ["rgba(0, 0, 0, 0)", "0px"], startup_surface

        driver.execute_async_script(
            "browser.storage.local.set({mode: 'allow',"
            "whiteList: ['google.com', 'asgverl.eltern-portal.org', 'example.org']})"
            ".then(arguments[arguments.length - 1])"
        )
        driver.refresh()
        driver.find_element(By.ID, "settings-summary").click()
        assert_settings_layout(driver, "website")
        site_rows = driver.execute_script(
            "const list = document.getElementById('site-row-scroll');"
            "const bounds = list.getBoundingClientRect();"
            "return {count: list.children.length, fullyVisible: [...list.children]"
            ".every(row => row.getBoundingClientRect().top >= bounds.top"
            " && row.getBoundingClientRect().bottom <= bounds.bottom),"
            "clientHeight: list.clientHeight, scrollHeight: list.scrollHeight}"
        )
        assert site_rows["count"] == 3 and site_rows["fullyVisible"], site_rows
        assert site_rows["scrollHeight"] <= site_rows["clientHeight"], site_rows
        if screenshot_dir:
            save_white_debug_screenshot(
                driver, Path(screenshot_dir) / "websites-three-sites-white-backdrop.png"
            )

        driver.find_element(By.ID, "unlock-phrase-setting-summary").click()
        WebDriverWait(driver, 5).until(
            lambda browser: browser.find_element(
                By.ID, "unlock-phrase-setting-dropdown"
            ).get_attribute("open") is not None
        )
        assert_settings_layout(driver, "phrase")
        phrase_field = driver.find_element(By.ID, "unlock-phrase-setting")
        field_height = phrase_field.rect["height"]
        phrase_top = phrase_field.rect["y"]
        assert len(phrase_field.get_attribute("value")) > 100
        assert phrase_field.get_property("scrollHeight") <= phrase_field.get_property("clientHeight")
        if screenshot_dir:
            save_white_debug_screenshot(
                driver, Path(screenshot_dir) / "pause-phrase-three-sites-white-backdrop.png"
            )
        phrase_field.send_keys(" extra")
        assert phrase_field.get_attribute("value").endswith(" extra")
        assert phrase_field.rect["height"] == field_height
        assert phrase_field.rect["y"] == phrase_top
        before_insert = phrase_field.get_attribute("value")
        driver.execute_script(
            "arguments[0].focus(); arguments[0].setSelectionRange(10, 10)", phrase_field
        )
        phrase_field.send_keys("X")
        driver.execute_async_script(
            "requestAnimationFrame(() => requestAnimationFrame(arguments[arguments.length - 1]))"
        )
        assert phrase_field.get_attribute("value") == (
            before_insert[:10] + "X" + before_insert[10:]
        )
        assert driver.execute_script("return arguments[0].selectionStart", phrase_field) == 11
        assert phrase_field.rect["height"] == field_height
        assert phrase_field.rect["y"] == phrase_top
        typed_value = phrase_field.get_attribute("value")
        driver.execute_async_script(
            "browser.storage.local.set({startupMode: 'allow'})"
            ".then(arguments[arguments.length - 1])"
        )
        WebDriverWait(driver, 5).until(
            lambda browser: browser.find_element(
                By.CSS_SELECTOR, '#startup-mode-segment [data-value="allow"]'
            ).get_attribute("aria-checked") == "true"
        )
        assert phrase_field.get_attribute("value") == typed_value
        assert driver.execute_script("return arguments[0].selectionStart", phrase_field) == 11
        assert phrase_field.rect["height"] == field_height
        assert phrase_field.rect["y"] == phrase_top
        assert_settings_layout(driver, "phrase")

        driver.find_element(By.ID, "website-settings-summary").click()
        WebDriverWait(driver, 5).until(
            lambda browser: browser.find_element(
                By.ID, "website-settings-dropdown"
            ).get_attribute("open") is not None
        )
        assert_settings_layout(driver, "website")

        driver.execute_async_script(
            "browser.storage.local.set({whiteList: Array.from({length: 12},"
            "(_, index) => `site${index}.example`)})"
            ".then(arguments[arguments.length - 1])"
        )
        driver.refresh()
        driver.find_element(By.ID, "settings-summary").click()
        assert_settings_layout(driver, "website")
        driver.find_element(By.CSS_SELECTOR, '#unlock-mode-segment [data-value="phrase"]').click()
        WebDriverWait(driver, 5).until(
            lambda browser: browser.find_element(
                By.ID, "unlock-phrase-setting-dropdown"
            ).get_attribute("open") is not None
        )
        assert_settings_layout(driver, "phrase")
        driver.find_element(By.ID, "website-settings-summary").click()
        WebDriverWait(driver, 5).until(
            lambda browser: browser.find_element(
                By.ID, "website-settings-dropdown"
            ).get_attribute("open") is not None
        )
        assert_settings_layout(driver, "website")
        driver.find_element(By.CSS_SELECTOR, '#unlock-mode-segment [data-value="timer"]').click()
        driver.execute_script(
            "const adult = document.getElementById('adult-content-control');"
            "adult.hidden = false;"
            "const warning = document.getElementById('timer-end-time-error');"
            "warning.hidden = false; warning.textContent = 'Invalid end time'"
        )
        assert_settings_layout(driver, "website", allow_area_scroll=True)
        print(
            f"Firefox {driver.capabilities['browserVersion']}: XPI installed; "
            "startup menu, content-sized layout, phrase typing, accordion, and persistence verified"
        )
    finally:
        driver.quit()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Firefox smoke test failed: {error}", file=sys.stderr)
        raise
