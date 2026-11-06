import Foundation

/// Playlists and guides shaped like the ones IPTV providers and relays serve,
/// junk included.
enum IPTVFixtures {
    /// A mix of everything the parser has to handle: header guide URLs, quoted
    /// attributes with commas, options before and after `#EXTINF`, FairPlay
    /// KODIPROPs (with Kodi's pipe suffix), VLC options, pipe headers, CRLF
    /// line ends, a BOM, comments, a broken entry and a non-http URL.
    static let extendedPlaylist = "\u{FEFF}#EXTM3U url-tvg=\"https://guide.example.com/a.xml,https://guide.example.com/b.xml.gz\" x-tvg-url=\"https://guide.example.com/a.xml\"\r\n"
        + """
        # a comment line
        #EXTINF:-1 tvg-id="news.one" tvg-name="News One" tvg-logo="https://img.example.com/news.png" group-title="News, Weather" tvg-chno="101",News One HD
        https://streams.example.com/news/index.m3u8
        #KODIPROP:inputstream.adaptive.license_type=com.apple.fps
        #KODIPROP:inputstream.adaptive.license_key=https://license.example.com/fps?ch=2|Content-Type=application/octet-stream|R{SSM}|
        #EXTINF:0 tvg-id='sport.two' group-title=Sports channel-number=7 ,Sport Two
        #KODIPROP:inputstream.adaptive.server_certificate=https://license.example.com/cert.der
        #EXTVLCOPT:http-user-agent=DuskTest/1.0
        #EXTVLCOPT:http-referrer=https://portal.example.com/
        https://streams.example.com/sport/master.m3u8
        #EXTGRP:Movies
        #EXTINF:-1 tvg-id="" ,Movies 24
        https://streams.example.com/movies.m3u8|User-Agent=PipeAgent%2F2&X-Token=abc
        #EXTINF:-1 tvg-id="broken"
        not a url at all
        #EXTINF:-1 tvg-id="rtmp.channel",RTMP Channel
        rtmp://streams.example.com/live
        #EXTINF:-1 tvg-id="widevine.channel",Widevine Channel
        #KODIPROP:inputstream.adaptive.license_type=com.widevine.alpha
        #KODIPROP:inputstream.adaptive.license_key=https://license.example.com/wv
        https://streams.example.com/wv.mpd

        https://streams.example.com/bare-entry.m3u8
        """

    static let guide = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE tv SYSTEM "xmltv.dtd">
    <tv generator-info-name="test">
      <channel id="news.one">
        <display-name lang="en">News One</display-name>
        <display-name>N1</display-name>
        <icon src="https://img.example.com/guide-news.png"/>
      </channel>
      <channel id="Sport.Two">
        <display-name>Sport Two</display-name>
        <icon src="https://img.example.com/guide-sport.png"/>
      </channel>
      <channel id="movies">
        <display-name>Movies 24</display-name>
      </channel>
      <programme start="20261106120000 +0000" stop="20261106130000 +0000" channel="news.one">
        <title lang="en">Midday News</title>
        <title lang="de">Mittagsnachrichten</title>
        <desc lang="en">Headlines &amp; weather.</desc>
        <icon src="https://img.example.com/midday.jpg"/>
      </programme>
      <programme start="20261106130000 +0000" stop="20261106140000 +0000" channel="news.one">
        <title>Afternoon Report</title>
        <sub-title>Markets</sub-title>
      </programme>
      <programme start="20261106143000 +0100" stop="20261106160000 +0100" channel="Sport.Two">
        <title><![CDATA[Grand Prix: Qualifying]]></title>
      </programme>
      <programme start="20261106120000" stop="20261106133000" channel="movies">
        <title>Feature Film</title>
      </programme>
      <programme start="20251106120000 +0000" stop="20251106130000 +0000" channel="news.one">
        <title>Last Year</title>
      </programme>
      <programme start="garbage" stop="20261106130000 +0000" channel="news.one">
        <title>Bad Time</title>
      </programme>
      <programme start="20261106120000 +0000" stop="20261106130000 +0000" channel="unknown.channel">
        <title>Not In Playlist</title>
      </programme>
    </tv>
    """

    /// 2026-11-06 12:00 UTC.
    static let guideNow = Date(timeIntervalSince1970: 1_793_966_400)
}
