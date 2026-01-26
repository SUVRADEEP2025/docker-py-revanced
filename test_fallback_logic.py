#!/usr/bin/env python3
"""Test script to verify the improved fallback download logic."""

from src.utils import get_fallback_sources_for_app, validate_download_source
from src.downloader.sources import APK_MIRROR_BASE_URL, UPTODOWN_SUFFIX, APK_PURE_BASE_URL


def test_get_fallback_sources():
    """Test getting fallback sources for various apps."""
    print("Testing fallback source retrieval...")
    
    # Test with known apps
    apps_to_test = ["youtube", "twitter", "reddit", "nonexistent_app"]
    
    for app in apps_to_test:
        sources = get_fallback_sources_for_app(app)
        print(f"  {app}: {len(sources)} sources found")
        if sources:
            print(f"    Sources: {sources[:3]}{'...' if len(sources) > 3 else ''}")  # Show first 3 only


def test_validate_download_source():
    """Test validation of download sources."""
    print("\nTesting source validation...")
    
    test_sources = [
        # Valid sources
        "https://www.apkmirror.com/apk/google-inc/youtube/",
        "https://youtube.en.uptodown.com/android",
        "https://apkpure.net/-/com.google.android.youtube",
        "apkeep",
        "local://somefile.jar",
        
        # Invalid sources
        "invalid-url",
        "",
        "ftp://example.com/file.apk",
    ]
    
    for source in test_sources:
        is_valid = validate_download_source(source)
        print(f"  '{source[:30]}{'...' if len(source) > 30 else ''}': {'VALID' if is_valid else 'INVALID'}")


def test_integration():
    """Test integration of both functions."""
    print("\nTesting integration...")
    
    app_name = "youtube"
    sources = get_fallback_sources_for_app(app_name)
    print(f"Fallback sources for {app_name}: {len(sources)} found")
    
    valid_sources = [source for source in sources if validate_download_source(source)]
    print(f"Valid sources after validation: {len(valid_sources)}")
    
    if valid_sources:
        print(f"First valid source: {valid_sources[0][:50]}...")
    

if __name__ == "__main__":
    print("Testing improved fallback download logic...\n")
    
    test_get_fallback_sources()
    test_validate_download_source()
    test_integration()
    
    print("\nAll tests completed!")