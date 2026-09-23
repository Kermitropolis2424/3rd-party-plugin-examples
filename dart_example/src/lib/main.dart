import 'dart:convert';
import 'wrapper.dart';

const String instanceHost = "https://xvideos.tv";
const int pageSize = 12;
bool progressThumbnailsCancelled = false;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _resolveUrl(String? path) {
  if (path == null || path.isEmpty) return "";
  if (path.startsWith("http://") || path.startsWith("https://")) return path;
  return "$instanceHost$path";
}

Map<String, dynamic> _formatVideoItem(Map<String, dynamic> item) {
  final channel = item["channel"] as Map<String, dynamic>? ?? {};
  final account = item["account"] as Map<String, dynamic>? ?? {};

  final likes = (item["likes"] as num?)?.toInt() ?? 0;
  final dislikes = (item["dislikes"] as num?)?.toInt() ?? 0;
  final totalRatings = likes + dislikes;
  final ratingPercent = totalRatings > 0 ? ((likes / totalRatings) * 100).round() : 100;

  return {
    "iD": item["uuid"]?.toString() ?? item["id"]?.toString() ?? "",
    "title": item["name"]?.toString() ?? "Untitled",
    "thumbnail": _resolveUrl(item["thumbnailPath"]?.toString()),
    "thumbnailHttpHeaders": null,
    "previewVideo": _resolveUrl(item["previewPath"]?.toString()),
    "previewVideoHttpHeaders": null,
    "duration": (item["duration"] as num?)?.toInt() ?? 0,
    "viewsTotal": (item["views"] as num?)?.toInt() ?? 0,
    "ratingsPositivePercent": ratingPercent,
    "maxQuality": 1080,
    "virtualReality": false,
    "authorName": channel["displayName"] ?? account["displayName"] ?? "Unknown",
    "authorID": channel["name"] ?? account["name"] ?? "",
    "verifiedAuthor": false,
    "scrapeFailMessage": null,
  };
}

// ---------------------------------------------------------------------------
// Core Lifecycle & Routing
// ---------------------------------------------------------------------------

Future<bool> init() async {
  consoleLog("info", "xvideos plugin initialized for $instanceHost");
  return true;
}

Future<bool> runFunctionalityTest() async {
  try {
    final res = await httpRequest("$instanceHost/api/v1/config");
    return res.status == 200;
  } catch (e) {
    consoleLog("error", "Functionality test failed: $e");
    return false;
  }
}

Future<Map<String, dynamic>> parseExternalLink(String uriString) async {
  final uri = Uri.parse(uriString);
  final segments = uri.pathSegments;

  if (segments.isEmpty) {
    return {"type": "homePage", "pageCount": 0};
  }

  // Handles: /w/:id or /videos/watch/:id
  if (segments.first == "w" && segments.length > 1) {
    return {"type": "videoPage", "iD": segments[1]};
  }
  if (segments.length >= 3 && segments[0] == "videos" && segments[1] == "watch") {
    return {"type": "videoPage", "iD": segments[2]};
  }

  // Handles: /c/:channelName or /video-channels/:channelName
  if ((segments.first == "c" || segments.first == "video-channels") && segments.length > 1) {
    return {"type": "authorPage", "iD": segments[1]};
  }

  // Handles: /search?search=query
  if (segments.first == "search" && uri.queryParameters.containsKey("search")) {
    return {
      "type": "searchResultsPage",
      "searchRequest": {
        "searchString": uri.queryParameters["search"] ?? "",
      },
      "pageCount": 0,
    };
  }

  return {"type": "unknown"};
}

// ---------------------------------------------------------------------------
// Feeds & Search
// ---------------------------------------------------------------------------

Future<List<Map<String, dynamic>>> getHomePage(int page) async {
  final start = page * pageSize;
  final url = "$instanceHost/api/v1/videos?start=$start&count=$pageSize&sort=-publishedAt";

  try {
    final response = await httpRequest(url);
    if (response.status != 200) return [];

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final List items = data["data"] as List? ?? [];

    return items.map((item) => _formatVideoItem(item as Map<String, dynamic>)).toList();
  } catch (e) {
    consoleLog("error", "getHomePage failed: $e");
    return [];
  }
}

Future<List<Map<String, dynamic>>> getSearchResults(
  Map<String, dynamic> request,
  int page,
) async {
  final query = Uri.encodeQueryComponent(request["searchString"] ?? "");
  final start = page * pageSize;
  final url = "$instanceHost/api/v1/search/videos?search=$query&start=$start&count=$pageSize";

  try {
    final response = await httpRequest(url);
    if (response.status != 200) return [];

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final List items = data["data"] as List? ?? [];

    return items.map((item) => _formatVideoItem(item as Map<String, dynamic>)).toList();
  } catch (e) {
    consoleLog("error", "getSearchResults failed: $e");
    return [];
  }
}

Future<List<String>> getSearchSuggestions(String searchString) async {
  return [];
}

// ---------------------------------------------------------------------------
// Video Details & Playback
// ---------------------------------------------------------------------------

String getVideoUriFromID(String videoID) => "$instanceHost/w/$videoID";

Future<Map<String, dynamic>> getVideoMetadata(
  String videoId,
  dynamic uvp,
) async {
  final url = "$instanceHost/api/v1/videos/$videoId";

  try {
    final response = await httpRequest(url);
    if (response.status != 200) {
      return {"iD": videoId, "scrapeFailMessage": "HTTP ${response.status}"};
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final channel = data["channel"] as Map<String, dynamic>? ?? {};
    final account = data["account"] as Map<String, dynamic>? ?? {};

    // Extract HLS playlist and standard MP4 streaming files
    final Map<int, String> streamUris = {};
    final streamingPlaylists = data["streamingPlaylists"] as List? ?? [];
    for (final playlist in streamingPlaylists) {
      final playlistUrl = playlist["playlistUrl"]?.toString();
      if (playlistUrl != null && playlistUrl.isNotEmpty) {
        streamUris[1080] = _resolveUrl(playlistUrl);
      }
    }

    if (streamUris.isEmpty) {
      final files = data["files"] as List? ?? [];
      for (final file in files) {
        final resObj = file["resolution"] as Map<String, dynamic>?;
        final res = (resObj?["id"] as num?)?.toInt() ?? 0;
        final fileUrl = file["fileUrl"]?.toString();
        if (fileUrl != null && res > 0) {
          streamUris[res] = _resolveUrl(fileUrl);
        }
      }
    }

    final likes = (data["likes"] as num?)?.toInt() ?? 0;
    final dislikes = (data["dislikes"] as num?)?.toInt() ?? 0;
    DateTime? publishedDate;
    if (data["publishedAt"] != null) {
      publishedDate = DateTime.tryParse(data["publishedAt"].toString());
    }

    return {
      "iD": videoId,
      "m3u8Uris": streamUris,
      "title": data["name"]?.toString() ?? "Untitled",
      "universalVideoPreview": uvp,
      "authorID": channel["name"] ?? account["name"] ?? "",
      "authorName": channel["displayName"] ?? account["displayName"] ?? "Unknown",
      "authorSubscriberCount": (channel["followersCount"] as num?)?.toInt() ?? 0,
      "authorAvatar": _resolveUrl(channel["avatar"]?["path"]?.toString()),
      "actors": [],
      "description": data["description"]?.toString() ?? "",
      "viewsTotal": (data["views"] as num?)?.toInt() ?? 0,
      "tags": (data["tags"] as List? ?? []).map((e) => e.toString()).toList(),
      "categories": [data["category"]?["label"]?.toString() ?? "General"],
      "uploadDate": (publishedDate?.millisecondsSinceEpoch ?? 0) ~/ 1000,
      "ratingsPositiveTotal": likes,
      "ratingsNegativeTotal": dislikes,
      "ratingsTotal": likes + dislikes,
      "virtualReality": false,
      "chapters": {},
      "rawHtml": response.body,
    };
  } catch (e) {
    return {"iD": videoId, "scrapeFailMessage": e.toString()};
  }
}

// ---------------------------------------------------------------------------
// Thumbnails & Media Downloads
// ---------------------------------------------------------------------------

Future<String> downloadThumbnail(
  String uri,
  Map<String, String>? thumbnailHttpHeaders,
) async {
  try {
    final response = await httpRequest(uri);
    return response.status == 200 ? response.body : "";
  } catch (e) {
    return "";
  }
}

Future<List<String>> getProgressThumbnails(
  String videoID,
  dynamic rawHtml,
) async {
  return [];
}

void cancelGetProgressThumbnails() {
  progressThumbnailsCancelled = true;
}

// ---------------------------------------------------------------------------
// Comments, Suggestions & Channels
// ---------------------------------------------------------------------------

Future<List<Map<String, dynamic>>> getVideoSuggestions(
  String videoID,
  dynamic rawHtml,
  int page,
) async {
  // Return trending/recent videos as suggestions
  return getHomePage(page);
}

String getCommentUriFromID(String commentID, String videoID) =>
    "$instanceHost/w/$videoID";

Future<List<Map<String, dynamic>>> getComments(
  String videoID,
  dynamic rawHtml,
  int page,
) async {
  final start = page * 10;
  final url = "$instanceHost/api/v1/videos/$videoID/comment-threads?start=$start&count=10";

  try {
    final response = await httpRequest(url);
    if (response.status != 200) return [];

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final List threads = data["data"] as List? ?? [];

    return threads.map((item) {
      final comment = item as Map<String, dynamic>;
      final account = comment["account"] as Map<String, dynamic>? ?? {};

      DateTime? created;
      if (comment["createdAt"] != null) {
        created = DateTime.tryParse(comment["createdAt"].toString());
      }

      return {
        "iD": comment["id"]?.toString() ?? "",
        "videoID": videoID,
        "author": account["displayName"] ?? account["name"] ?? "Anonymous",
        "commentBody": comment["text"]?.toString() ?? "",
        "hidden": false,
        "authorID": account["name"] ?? "",
        "countryID": "US",
        "orientation": null,
        "profilePicture": _resolveUrl(account["avatar"]?["path"]?.toString()),
        "ratingsPositiveTotal": null,
        "ratingsNegativeTotal": null,
        "ratingsTotal": 0,
        "commentDate": (created?.millisecondsSinceEpoch ?? 0) ~/ 1000,
        "replyComments": [],
        "scrapeFailMessage": null,
      };
    }).toList();
  } catch (e) {
    return [];
  }
}

String getAuthorUriFromID(String authorID) => "$instanceHost/c/$authorID";

Future<Map<String, dynamic>> getAuthorPage(String authorID) async {
  final url = "$instanceHost/api/v1/video-channels/$authorID";

  try {
    final response = await httpRequest(url);
    if (response.status != 200) {
      return {"iD": authorID, "name": authorID};
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    return {
      "iD": authorID,
      "name": data["displayName"] ?? data["name"] ?? authorID,
      "avatar": _resolveUrl(data["avatar"]?["path"]?.toString()),
      "banner": _resolveUrl(data["banner"]?["path"]?.toString()),
      "aliases": [],
      "description": data["description"]?.toString() ?? "",
      "advancedDescription": {},
      "externalLinks": {},
      "viewsTotal": (data["views"] as num?)?.toInt() ?? 0,
      "videosTotal": 0,
      "subscribers": (data["followersCount"] as num?)?.toInt() ?? 0,
      "rank": 0,
      "rawHtml": response.body,
    };
  } catch (e) {
    return {"iD": authorID, "name": authorID};
  }
}

Future<List<Map<String, dynamic>>> getAuthorVideos(
  String authorID,
  int page,
) async {
  final start = page * pageSize;
  final url = "$instanceHost/api/v1/video-channels/$authorID/videos?start=$start&count=$pageSize";

  try {
    final response = await httpRequest(url);
    if (response.status != 200) return [];

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final List items = data["data"] as List? ?? [];

    return items.map((item) => _formatVideoItem(item as Map<String, dynamic>)).toList();
  } catch (e) {
    consoleLog("error", "getAuthorVideos failed: $e");
    return [];
  }
}
// Core Lifecycle & Routing
// ---------------------------------------------------------------------------

Future<bool> init() async {
  consoleLog("info", "PeerTube plugin initialized for $instanceHost");
  return true;
}

Future<bool> runFunctionalityTest() async {
  try {
    final res = await httpRequest("$instanceHost/api/v1/config");
    return res.status == 200;
  } catch (e) {
    consoleLog("error", "Functionality test failed: $e");
    return false;
  }
}

Future<Map<String, dynamic>> parseExternalLink(String uriString) async {
  final uri = Uri.parse(uriString);
  final segments = uri.pathSegments;

  if (segments.isEmpty) {
    return {"type": "homePage", "pageCount": 0};
  }

  // Handles: /w/:id or /videos/watch/:id
  if (segments.first == "w" && segments.length > 1) {
    return {"type": "videoPage", "iD": segments[1]};
  }
  if (segments.length >= 3 && segments[0] == "videos" && segments[1] == "watch") {
    return {"type": "videoPage", "iD": segments[2]};
  }

  // Handles: /c/:channelName or /video-channels/:channelName
  if ((segments.first == "c" || segments.first == "video-channels") && segments.length > 1) {
    return {"type": "authorPage", "iD": segments[1]};
  }

  // Handles: /search?search=query
  if (segments.first == "search" && uri.queryParameters.containsKey("search")) {
    return {
      "type": "searchResultsPage",
      "searchRequest": {
        "searchString": uri.queryParameters["search"] ?? "",
      },
      "pageCount": 0,
    };
  }

  return {"type": "unknown"};
}

// ---------------------------------------------------------------------------
// Feeds & Search
// ---------------------------------------------------------------------------

Future<List<Map<String, dynamic>>> getHomePage(int page) async {
  final start = page * pageSize;
  final url = "$instanceHost/api/v1/videos?start=$start&count=$pageSize&sort=-publishedAt";

  try {
    final response = await httpRequest(url);
    if (response.status != 200) return [];

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final List items = data["data"] as List? ?? [];

    return items.map((item) => _formatVideoItem(item as Map<String, dynamic>)).toList();
  } catch (e) {
    consoleLog("error", "getHomePage failed: $e");
    return [];
  }
}

Future<List<Map<String, dynamic>>> getSearchResults(
  Map<String, dynamic> request,
  int page,
) async {
  final query = Uri.encodeQueryComponent(request["searchString"] ?? "");
  final start = page * pageSize;
  final url = "$instanceHost/api/v1/search/videos?search=$query&start=$start&count=$pageSize";

  try {
    final response = await httpRequest(url);
    if (response.status != 200) return [];

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final List items = data["data"] as List? ?? [];

    return items.map((item) => _formatVideoItem(item as Map<String, dynamic>)).toList();
  } catch (e) {
    consoleLog("error", "getSearchResults failed: $e");
    return [];
  }
}

Future<List<String>> getSearchSuggestions(String searchString) async {
  return [];
}

// ---------------------------------------------------------------------------
// Video Details & Playback
// ---------------------------------------------------------------------------

String getVideoUriFromID(String videoID) => "$instanceHost/w/$videoID";

Future<Map<String, dynamic>> getVideoMetadata(
  String videoId,
  dynamic uvp,
) async {
  final url = "$instanceHost/api/v1/videos/$videoId";

  try {
    final response = await httpRequest(url);
    if (response.status != 200) {
      return {"iD": videoId, "scrapeFailMessage": "HTTP ${response.status}"};
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final channel = data["channel"] as Map<String, dynamic>? ?? {};
    final account = data["account"] as Map<String, dynamic>? ?? {};

    // Extract HLS playlist and standard MP4 streaming files
    final Map<int, String> streamUris = {};
    final streamingPlaylists = data["streamingPlaylists"] as List? ?? [];
    for (final playlist in streamingPlaylists) {
      final playlistUrl = playlist["playlistUrl"]?.toString();
      if (playlistUrl != null && playlistUrl.isNotEmpty) {
        streamUris[1080] = _resolveUrl(playlistUrl);
      }
    }

    if (streamUris.isEmpty) {
      final files = data["files"] as List? ?? [];
      for (final file in files) {
        final resObj = file["resolution"] as Map<String, dynamic>?;
        final res = (resObj?["id"] as num?)?.toInt() ?? 0;
        final fileUrl = file["fileUrl"]?.toString();
        if (fileUrl != null && res > 0) {
          streamUris[res] = _resolveUrl(fileUrl);
        }
      }
    }

    final likes = (data["likes"] as num?)?.toInt() ?? 0;
    final dislikes = (data["dislikes"] as num?)?.toInt() ?? 0;
    DateTime? publishedDate;
    if (data["publishedAt"] != null) {
      publishedDate = DateTime.tryParse(data["publishedAt"].toString());
    }

    return {
      "iD": videoId,
      "m3u8Uris": streamUris,
      "title": data["name"]?.toString() ?? "Untitled",
      "universalVideoPreview": uvp,
      "authorID": channel["name"] ?? account["name"] ?? "",
      "authorName": channel["displayName"] ?? account["displayName"] ?? "Unknown",
      "authorSubscriberCount": (channel["followersCount"] as num?)?.toInt() ?? 0,
      "authorAvatar": _resolveUrl(channel["avatar"]?["path"]?.toString()),
      "actors": [],
      "description": data["description"]?.toString() ?? "",
      "viewsTotal": (data["views"] as num?)?.toInt() ?? 0,
      "tags": (data["tags"] as List? ?? []).map((e) => e.toString()).toList(),
      "categories": [data["category"]?["label"]?.toString() ?? "General"],
      "uploadDate": (publishedDate?.millisecondsSinceEpoch ?? 0) ~/ 1000,
      "ratingsPositiveTotal": likes,
      "ratingsNegativeTotal": dislikes,
      "ratingsTotal": likes + dislikes,
      "virtualReality": false,
      "chapters": {},
      "rawHtml": response.body,
    };
  } catch (e) {
    return {"iD": videoId, "scrapeFailMessage": e.toString()};
  }
}

// ---------------------------------------------------------------------------
// Thumbnails & Media Downloads
// ---------------------------------------------------------------------------

Future<String> downloadThumbnail(
  String uri,
  Map<String, String>? thumbnailHttpHeaders,
) async {
  try {
    final response = await httpRequest(uri);
    return response.status == 200 ? response.body : "";
  } catch (e) {
    return "";
  }
}

Future<List<String>> getProgressThumbnails(
  String videoID,
  dynamic rawHtml,
) async {
  return [];
}

void cancelGetProgressThumbnails() {
  progressThumbnailsCancelled = true;
}

// ---------------------------------------------------------------------------
// Comments, Suggestions & Channels
// ---------------------------------------------------------------------------

Future<List<Map<String, dynamic>>> getVideoSuggestions(
  String videoID,
  dynamic rawHtml,
  int page,
) async {
  // Return trending/recent videos as suggestions
  return getHomePage(page);
}

String getCommentUriFromID(String commentID, String videoID) =>
    "$instanceHost/w/$videoID";

Future<List<Map<String, dynamic>>> getComments(
  String videoID,
  dynamic rawHtml,
  int page,
) async {
  final start = page * 10;
  final url = "$instanceHost/api/v1/videos/$videoID/comment-threads?start=$start&count=10";

  try {
    final response = await httpRequest(url);
    if (response.status != 200) return [];

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final List threads = data["data"] as List? ?? [];

    return threads.map((item) {
      final comment = item as Map<String, dynamic>;
      final account = comment["account"] as Map<String, dynamic>? ?? {};

      DateTime? created;
      if (comment["createdAt"] != null) {
        created = DateTime.tryParse(comment["createdAt"].toString());
      }

      return {
        "iD": comment["id"]?.toString() ?? "",
        "videoID": videoID,
        "author": account["displayName"] ?? account["name"] ?? "Anonymous",
        "commentBody": comment["text"]?.toString() ?? "",
        "hidden": false,
        "authorID": account["name"] ?? "",
        "countryID": "US",
        "orientation": null,
        "profilePicture": _resolveUrl(account["avatar"]?["path"]?.toString()),
        "ratingsPositiveTotal": null,
        "ratingsNegativeTotal": null,
        "ratingsTotal": 0,
        "commentDate": (created?.millisecondsSinceEpoch ?? 0) ~/ 1000,
        "replyComments": [],
        "scrapeFailMessage": null,
      };
    }).toList();
  } catch (e) {
    return [];
  }
}

String getAuthorUriFromID(String authorID) => "$instanceHost/c/$authorID";

Future<Map<String, dynamic>> getAuthorPage(String authorID) async {
  final url = "$instanceHost/api/v1/video-channels/$authorID";

  try {
    final response = await httpRequest(url);
    if (response.status != 200) {
      return {"iD": authorID, "name": authorID};
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    return {
      "iD": authorID,
      "name": data["displayName"] ?? data["name"] ?? authorID,
      "avatar": _resolveUrl(data["avatar"]?["path"]?.toString()),
      "banner": _resolveUrl(data["banner"]?["path"]?.toString()),
      "aliases": [],
      "description": data["description"]?.toString() ?? "",
      "advancedDescription": {},
      "externalLinks": {},
      "viewsTotal": (data["views"] as num?)?.toInt() ?? 0,
      "videosTotal": 0,
      "subscribers": (data["followersCount"] as num?)?.toInt() ?? 0,
      "rank": 0,
      "rawHtml": response.body,
    };
  } catch (e) {
    return {"iD": authorID, "name": authorID};
  }
}

Future<List<Map<String, dynamic>>> getAuthorVideos(
  String authorID,
  int page,
) async {
  final start = page * pageSize;
  final url = "$instanceHost/api/v1/video-channels/$authorID/videos?start=$start&count=$pageSize";

  try {
    final response = await httpRequest(url);
    if (response.status != 200) return [];

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final List items = data["data"] as List? ?? [];

    return items.map((item) => _formatVideoItem(item as Map<String, dynamic>)).toList();
  } catch (e) {
    consoleLog("error", "getAuthorVideos failed: $e");
    return [];
  }
}
  final args = uri.queryParameters;

  switch (uri.path) {
    case "/home":
      return {"type": "homePage", "pageCount": int.parse(args["page"] ?? "0")};

    case "/search":
      return {
        "type": "searchResultsPage",
        "searchRequest": {
          "searchString": Uri.decodeQueryComponent(args["query"] ?? ""),
          "sortingType": args["sortingType"],
          "dateRange": args["dateRange"],
          "minQuality": int.parse(args["minQuality"] ?? "0"),
          "maxQuality": int.parse(args["maxQuality"] ?? "0"),
          "minDuration": int.parse(args["minDuration"] ?? "0"),
          "maxDuration": int.parse(args["maxDuration"] ?? "0"),
          "minFramesPerSecond": int.parse(args["minFramesPerSecond"] ?? "0"),
          "maxFramesPerSecond": int.parse(args["maxFramesPerSecond"] ?? "0"),
          "virtualReality": args["virtualReality"] != null
              ? args["virtualReality"] == "true"
              : null,
        },
        "pageCount": int.parse(args["page"] ?? "0"),
      };

    case "/video":
      return {"type": "videoPage", "iD": args["videoId"]};

    case "/author":
      return {"type": "authorPage", "iD": args["authorId"]};

    default:
      return {"type": "unknown"};
  }
}

Future<List<Map<String, dynamic>>> getHomePage(int page) async {
  if (simulateDelays) await Future.delayed(const Duration(seconds: 2));
  return List.generate(
    10,
    (index) => {
      "iD": (index * pi * 10000).toInt().toString(),
      "title": "Test homepage video $index, page $page",
      "thumbnail": "https://placehold.co/1280x720.png",
      "thumbnailHttpHeaders": {"X-Ignore": "example-header"},
      "previewVideo":
          "https://docs.evostream.com/sample_content/assets/bunny.mp4",
      "previewVideoHttpHeaders": {"X-Ignore": "example-header"},
      "duration": 120 + index * 10, // seconds
      "viewsTotal": (index * pi * 1000000).toInt(),
      "ratingsPositivePercent": (index * pi * 10).toInt() % 101,
      "maxQuality": 720,
      "virtualReality": false,
      "authorName": "Tester-author $index",
      "authorID": "Tester-author $index",
      "verifiedAuthor": index % 2 == 0,
      // Make every 4th video a fail
      "scrapeFailMessage": index % 4 != 0 ? "Test fail scrape message" : null,
    },
  );
}

Future<String> downloadThumbnail(
  String uri,
  Map<String, String>? thumbnailHttpHeaders,
) async {
  try {
    final response = await httpRequest(uri);
    if (response.status == 200) {
      return response.body; // base64 encoded bytes
    } else {
      consoleLog("error", "Error downloading thumbnail: ${response.status}");
      return "";
    }
  } catch (e) {
    consoleLog("error", "Error downloading thumbnail: $e");
    return "";
  }
}

Future<List<String>> getSearchSuggestions(String searchString) async {
  if (simulateDelays) await Future.delayed(const Duration(milliseconds: 200));
  return List.generate(5, (index) => "$searchString-$index");
}

Future<List<Map<String, dynamic>>> getSearchResults(
  Map<String, dynamic> request,
  int page,
) async {
  if (simulateDelays) await Future.delayed(const Duration(seconds: 2));
  if (page == 5) return [];
  return List.generate(
    10,
    (index) => {
      "iD": (index * pi * 10000).toInt().toString(),
      "title":
          "Test result video $index, page $page, request ${request["searchString"]}",
      "thumbnail": "https://placehold.co/1280x720.png",
      "thumbnailHttpHeaders": {"X-Ignore": "example-header"},
      "previewVideo":
          "https://docs.evostream.com/sample_content/assets/bunny.mp4",
      "previewVideoHttpHeaders": {"X-Ignore": "example-header"},
      "duration": 120 + index * 10, // seconds
      "viewsTotal": (index * pi * 1000000).toInt(),
      "ratingsPositivePercent": (index * pi * 10000).toInt() == 0
          ? 50
          : (index * pi * 10000).toInt(),
      "maxQuality": 720,
      "virtualReality": false,
      "authorName": "Tester-author $index",
      "authorID": "Tester-author $index",
      "verifiedAuthor": index % 2 == 0,
      // Make every 4th video a fail
      "scrapeFailMessage": index % 4 != 0 ? "Test fail scrape message" : null,
    },
  );
}

String getVideoUriFromID(String videoID) => "https://example.com/$videoID";

Future<Map<String, dynamic>> getVideoMetadata(
  String videoId,
  dynamic uvp,
) async {
  if (simulateDelays) await Future.delayed(const Duration(seconds: 2));
  return {
    "iD": videoId,
    "m3u8Uris": {
      1080: "https://docs.evostream.com/sample_content/assets/bunny.mp4",
      720: "https://docs.evostream.com/sample_content/assets/bunny.mp4",
      480: "https://docs.evostream.com/sample_content/assets/bunny.mp4",
    },
    "title": "Tester video metadata title",
    "universalVideoPreview": uvp,
    // Change this to test partial metadata scrape fail
    //"scrapeFailMessage": "Test fail scrape message",
    "authorID": "tester-author-$videoId",
    "authorName": "Tester-author",
    "authorSubscriberCount": 335433,
    "authorAvatar": "https://placehold.co/1280x720.png",
    "actors": [
      {
        "name": "Tester-actor-1",
        "authorID": "Tester-author-actor-1",
        "avatar": "https://placehold.co/200x200.png",
      },
      {
        "name": "Tester-actor-2",
        "authorID": "Tester-author-actor-2",
        "avatar": "https://placehold.co/200x200.png",
      },
    ],
    "description": "Tester video description" * 10,
    "viewsTotal": 2532823,
    "tags": ["Tester-tag-1", "Tester-tag-2"],
    "categories": ["Tester-category-1", "Tester-category-2"],
    "uploadDate": DateTime.now().millisecondsSinceEpoch ~/ 1000,
    "ratingsPositiveTotal": 90,
    "ratingsNegativeTotal": 10,
    "ratingsTotal": 47384,
    "virtualReality": false,
    "chapters": {0: "Chapter 1", 120: "Chapter 2", 240: "Chapter 3"},
    "rawHtml": null,
  };
}

Future<List<String>> getProgressThumbnails(
  String videoID,
  dynamic rawHtml,
) async {
  // reset cancellation flag
  progressThumbnailsCancelled = false;
  // Simulate heavy processing (split into chunks so cancellation can be checked)
  for (int i = 0; i < 50; i++) {
    if (progressThumbnailsCancelled) return [];
    await Future.delayed(const Duration(milliseconds: 100));
  }
  if (progressThumbnailsCancelled) return [];
  final response = await httpRequest("https://placehold.co/720x480.png");
  if (response.status != 200)
    throw Exception("Failed to download/convert placeholder image");
  if (progressThumbnailsCancelled) return [];
  // Return 1000 copies of the same image (base64 encoded body)
  return List.filled(1000, response.body);
}

void cancelGetProgressThumbnails() {
  progressThumbnailsCancelled = true;
  consoleLog("warning", "Set flag to cancel getProgressThumbnails");
}

String getCommentUriFromID(String commentID, String videoID) =>
    "https://example.com/$videoID/$commentID";

Future<List<Map<String, dynamic>>> getComments(
  String videoID,
  dynamic rawHtml,
  int page,
) async {
  if (page == 5) return [];
  if (simulateDelays) await Future.delayed(const Duration(seconds: 2));
  return List.generate(
    10,
    (index) => {
      "iD": "comment-$index",
      "videoID": videoID,
      "author": "author-$index",
      "commentBody": List.filled(
        5,
        "test comment $index, page $page ",
      ).join(""),
      "hidden": index % 4 == 0,
      "authorID": "author-$index",
      "countryID": "US",
      "orientation": null,
      "profilePicture": "https://placehold.co/240x240.png",
      "ratingsPositiveTotal": index % 4 == 0 ? 30 : null,
      "ratingsNegativeTotal": index % 4 == 0 ? 2 : null,
      "ratingsTotal": index % 4 == 0 ? 32 : 76,
      "commentDate": DateTime.now().millisecondsSinceEpoch ~/ 1000,
      "replyComments": index % 2 == 0
          ? List.generate(
              3,
              (index) => {
                "iD": "comment-reply-$index",
                "videoID": videoID,
                "author": "author-reply-$index",
                "commentBody": List.filled(
                  5,
                  "test reply comment $index ",
                ).join(""),
                "hidden": index % 4 == 0,
                "authorID": "author-reply-$index",
                "countryID": "US",
                "orientation": null,
                "profilePicture": "https://placehold.co/240x240",
                "ratingsPositiveTotal": index % 2 == 0 ? 4 : null,
                "ratingsNegativeTotal": index % 2 == 0 ? 1 : null,
                "ratingsTotal": index % 2 == 0 ? 5 : 6,
                "commentDate": DateTime.now().millisecondsSinceEpoch ~/ 1000,
                "replyComments": [],
                // Make every 4th comment a fail
                "scrapeFailMessage": index % 4 != 0
                    ? "Test fail scrape message"
                    : null,
              },
            )
          : [],
      // Make every 4th comment a fail
      "scrapeFailMessage": index % 4 != 0 ? "Test fail scrape message" : null,
    },
  );
}

Future<List<Map<String, dynamic>>> getVideoSuggestions(
  String videoID,
  dynamic rawHtml,
  int page,
) async {
  if (simulateDelays) await Future.delayed(const Duration(seconds: 2));
  if (page == 5) return [];
  return List.generate(
    10,
    (index) => {
      "iD": (index * pi * 10000).toInt().toString(),
      "title": "Test suggestion video $index",
      "thumbnail": "https://placehold.co/1280x720.png",
      "thumbnailHttpHeaders": {"X-Ignore": "example-header"},
      "previewVideo":
          "https://docs.evostream.com/sample_content/assets/bunny.mp4",
      "previewVideoHttpHeaders": {"X-Ignore": "example-header"},
      "duration": 120 + index * 10, // seconds
      "viewsTotal": (index * pi * 1000000).toInt(),
      "ratingsPositivePercent": (index * pi * 10000).toInt() == 0
          ? 50
          : (index * pi * 10000).toInt(),
      "maxQuality": 720,
      "virtualReality": false,
      "authorName": "Tester-suggestion-author $index",
      "authorID": "Tester-suggestion-author $index",
      "verifiedAuthor": index % 2 == 0,
      // Make every 4th video a fail
      "scrapeFailMessage": index % 4 != 0 ? "Test fail scrape message" : null,
    },
  );
}

String getAuthorUriFromID(String authorID) => "https://example.com/$authorID";

Future<Map<String, dynamic>> getAuthorPage(String authorID) async {
  if (simulateDelays) await Future.delayed(const Duration(seconds: 2));
  return {
    "iD": authorID,
    "name": "Test author name",
    "avatar": "https://placehold.co/240x240.png",
    "banner": "https://placehold.co/1270x400.png",
    "aliases": ["Test alias 1", "Test alias 2"],
    "description": "Very long description" * 1000,
    "advancedDescription": Map.fromEntries(
      List.generate(
        1000,
        (i) => MapEntry(
          "Test description key ${i + 1}",
          "Test description value ${i + 1}",
        ),
      ),
    ),
    "externalLinks": {
      "external link 1": "https://example.com/link1",
      "external link 2": "https://example.com/link2",
      "external link 3": "https://example.com/link3",
    },
    "viewsTotal": 23773212,
    "videosTotal": 114,
    "subscribers": 573529,
    "rank": 3746,
    "rawHtml": "",
  };
}

Future<List<Map<String, dynamic>>> getAuthorVideos(
  String authorID,
  int page,
) async {
  if (simulateDelays) await Future.delayed(const Duration(seconds: 2));
  if (page == 5) return [];
  return List.generate(
    10,
    (index) => {
      "iD": (index * pi * 10000).toInt().toString(),
      "title": "Test author video $index, page $page",
      "thumbnail": "https://placehold.co/1280x720.png",
      "thumbnailHttpHeaders": {"X-Ignore": "example-header"},
      "previewVideo":
          "https://docs.evostream.com/sample_content/assets/bunny.mp4",
      "previewVideoHttpHeaders": {"X-Ignore": "example-header"},
      "duration": 120 + index * 10, // seconds
      "viewsTotal": (index * pi * 1000000).toInt(),
      "ratingsPositivePercent": (index * pi * 10000).toInt() == 0
          ? 50
          : (index * pi * 10000).toInt(),
      "maxQuality": 720,
      "virtualReality": false,
      "authorName": "Tester-author-same $index",
      "authorID": "Tester-author-same $index",
      "verifiedAuthor": index % 2 == 0,
      // Make every 4th video a fail
      "scrapeFailMessage": index % 4 != 0 ? "Test fail scrape message" : null,
    },
  );
}
