import 'dart:convert' as Convert;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart';
import 'package:intl/intl.dart';
import 'package:kamino/main.dart';
import 'package:kamino/models/source.dart';
import 'package:kamino/ui/interface.dart';
import 'package:kamino/util/settings.dart';
import 'package:kamino/vendor/struct/VendorService.dart';
import 'package:ntp/ntp.dart';
import 'package:w_transport/w_transport.dart' as Transport;
import 'package:w_transport/vm.dart' show vmTransportPlatform;

class ClawsVendorService extends VendorService {

  // Settings
  static const bool ALLOW_SOURCE_SELECTION = true;
  static const bool FORCE_TOKEN_REGENERATION = true;

  // Claws information
  final String server;
  final String clawsKey;
  final bool isOfficial;

  ClawsVendorService({
    this.server,
    this.clawsKey,
    this.isOfficial = false,
    @required bool allowSourceSelection
  }) : super(
    allowSourceSelection: allowSourceSelection,
    isNetworkService: true
  );

  Transport.WebSocket _webSocket;
  String _token;

  @override
  Future<bool> initialize(BuildContext context) async {
    this.setStatus(context, VendorServiceStatus.INITIALIZING);

    /* ATTEMPT TO CONNECT TO SERVER */
    try {
      Response response = await get(server + 'api/v1/status').timeout(Duration(seconds: 10), onTimeout: () => null);

      if(response != null && response.statusCode == 200) {
        var status = Convert.jsonDecode(response.body);
        return true;
      }

      this.setStatus(context, VendorServiceStatus.IDLE);
      Interface.showSimpleErrorDialog(
          context,
          title: "Unable to connect...",
          reason: "The request timed out.\n\n(Is your connection too slow?)"
      );
      return false;
    }catch(ex){
      this.setStatus(context, VendorServiceStatus.IDLE);
      print("Exception whilst determining Claws status: $ex");

      Interface.showSimpleErrorDialog(context,
          title: "Unable to connect...",
          reason: isOfficial
              ? "The $appName server is currently offline for server upgrades.\nPlease check the #announcements channel in our Discord server for more information."
              : "Unable to connect to server."
      );
      return false;
    }
  }

  @override
  Future<bool> authenticate(BuildContext context) async {
    if(this.status != VendorServiceStatus.INITIALIZING) return false;
    this.setStatus(context, VendorServiceStatus.AUTHENTICATING);

    String token = await Settings.clawsToken;
    double tokenSetTime = await Settings.clawsTokenSetTime;

    DateTime now = await NTP.now();
    if(!FORCE_TOKEN_REGENERATION
        && token != null
        && (tokenSetTime + 3600) >= (now.millisecondsSinceEpoch / 1000).floor()
    ){
      print("Attempting to re-use token...");

      // TODO: Check that token is still valid when reusing!

      _token = token;
      return true;
    }else{
      var clawsClientHash;

      try {
        clawsClientHash = await _generateClawsHash(clawsKey, now).timeout(
            Duration(seconds: 5),
            onTimeout: () => null
        );
      }catch(ex){
        print(ex);
      }

      if(clawsClientHash == null){
        this.setStatus(context, VendorServiceStatus.IDLE);
        Interface.showSimpleErrorDialog(
            context, title: "Unable to connect...",
            reason: "Authentication timed out. Please try again.\n\nIf this problem persists, please contact a member of staff on Discord."
        );
        return false;
      }

      Response response;
      try {
        response = await post(
            server + 'api/v1/login',
            body: Convert.jsonEncode({"clientID": clawsClientHash}),
            headers: {"Content-Type": "application/json"}
        ).timeout(Duration(seconds: 10), onTimeout: () async {
          return null;
        });
      }catch(ex){}

      if(response == null || response.statusCode != 200){
        this.setStatus(context, VendorServiceStatus.IDLE);
        Interface.showSimpleErrorDialog(
            context, title: "Authentication failed...",
            reason: "The server could not verify the app's integrity. (Is your copy of the app out of date?)"
        );
        return false;
      }

      var tokenResponse = Convert.jsonDecode(response.body);

      try {
        if (tokenResponse["auth"]) {
          var token = tokenResponse["token"];
          var tokenJson = jwtDecode(token);
          await (Settings.clawsToken = token);
          await (Settings.clawsTokenSetTime = tokenJson['exp'].toDouble());
          print("Generated new token...");
          _token = token;

          return true;
        }
      }catch(ex){}

      this.setStatus(context, VendorServiceStatus.IDLE);
      Interface.showSimpleErrorDialog(context, title: "Unable to connect...", reason: tokenResponse["message"]);
      return false;
    }
  }

  @override
  Future<void> playMovie(String title, String releaseDate, BuildContext context) async {
    if(!await initialize(context)) return;

    var year = new DateFormat.y("en_US").format(DateTime.parse(releaseDate) ?? '');

    String clawsToken = _token;
    String webSocketServer = server.replaceFirst(new RegExp(r'https?'), "ws").replaceFirst(new RegExp(r'http?'), "ws");
    String endpointURL = "$webSocketServer?token=$clawsToken";
    String data = '{"type": "movies", "title": "$title", "year": "$year"}';

    if(!await authenticate(context)) return;
    _beginProcessing(context, endpointURL, data, title);
  }

  @override
  Future<void> playTVShow(String title, String releaseDate, int seasonNumber, int episodeNumber, BuildContext context) async {
    if(!await initialize(context)) return;

    var year = new DateFormat.y("en_US").format(DateTime.parse(releaseDate) ?? '');
    var displayTitle = "$title \u2022 S${seasonNumber.toString().padLeft(2, '0')} E$episodeNumber";

    String clawsToken = _token;
    String webSocketServer = server.replaceFirst(new RegExp(r'https?'), "ws").replaceFirst(new RegExp(r'http?'), "ws");
    String endpointURL = "$webSocketServer?token=$clawsToken";
    String data = '{"type": "tv", "title": "$title", "year": "$year", "season": "$seasonNumber", "episode": "$episodeNumber"}';

    if(!await authenticate(context)) return;
    _beginProcessing(context, endpointURL, data, title, displayTitle: displayTitle);
  }

  ///
  /// Once authenticated with the server, this method will handle interaction
  /// with the websocket to get results.
  ///
  _beginProcessing(BuildContext context, String url, String data, String title, { String displayTitle }) async {
    // Prepare to process the information.
    this.setStatus(context, VendorServiceStatus.PROCESSING, title: displayTitle);
    if(displayTitle == null) displayTitle = title;

    // Connect to the websocket server...
    try {
      _webSocket = await Transport.WebSocket.connect(
          Uri.parse(url),
          transportPlatform: vmTransportPlatform
      ).timeout(
          Duration(seconds: 10),
          onTimeout: () => null
      );
    }catch(ex){
      this.setStatus(context, VendorServiceStatus.IDLE);
      Interface.showSimpleErrorDialog(context, title: "Scraping failed...", reason: "The socket connection failed.");
      print(ex.toString());
      return;
    }

    if(_webSocket == null){
      this.setStatus(context, VendorServiceStatus.IDLE);
      Interface.showSimpleErrorDialog(context, title: "Scraping failed...", reason: "The socket connection timed out. (Is your connection to slow?)");
      return;
    }

    int pendingScrapes = 0;

    // Initialize the websocket client.
    _webSocket.listen((message) async {

      try {
        var event = Convert.jsonDecode(message);
        String eventName = event['event'];

        switch (eventName) {
          case 'status':
            print(event);
            break;

          ///
          /// Some sources return URLs that are IP-bound. Meaning data can only be
          /// subsequently accessed from that URL if it is from the IP that
          /// initially retrieved the URL.
          ///
          /// To get around this, Claws uses 'scrape' events. These events return
          /// a URL that the client should request the HTML from and then send to
          /// Claws for analysis.
          ///
          /// For more information, please visit
          /// https://github.com/ApolloTVofficial/Claws/wiki/IP-Locking
          ///
          case 'scrape':
          // Ensure that the headers array is not null.
            if (event['headers'] == null) {
              event['headers'] = new Map<String, String>();
            }

            var cookie = '';
            Response htmlContent;

            // Attempt to receive and process HTML content from source.
            try {
              htmlContent = await get(
                  event['target'],
                  headers: event['headers']
              );

              if (event['cookieRequired'] != '') {
                var cookieKey = event['cookieRequired'];
                var cookieList = htmlContent.headers['set-cookie'].split(',');
                cookie =
                    cookieList.lastWhere((String i) => i.contains(cookieKey))
                        .split(';').firstWhere((String i) =>
                        i.contains(cookieKey));
              }
            } catch (ex) {
              print(
                  "An error occurred whilst fetching HTML content for analysis from source. (${event['target']})");
              return;
            }

            // Now send the HTML content to Claws for analysis.
            try {
              String message = Convert.jsonEncode({
                'type': 'resolveHtml',
                'provider': event['provider'],
                'resolver': event['resolver'],
                'cookie': cookie,
                'html': Convert.base64.encode(
                    Convert.utf8.encode(htmlContent.body)
                )
              });

              _webSocket.add(message);
              pendingScrapes++;
            } catch (ex) {
              print(
                  "An error occurred whilst submitting HTML content to Claws for analysis.");
            }
            break;

          ///
          /// Once Claws has found a result from a source, it is sent to the
          /// client in the form of a 'result' event.
          ///
          /// These contain a stream URL that can be played by the client as well
          /// as some metadata about the URL, such as quality information.
          ///
          case 'result':
            print(event['isResultOfScrape']);
            if (event['isResultOfScrape']) {
              pendingScrapes--;
            }

            if (event['error'] != null) {
              return;
            }

            var sourceFile = event['file'];
            if (sourceFile == null) return;
            var sourceMeta = event['metadata'];
            String sourceStreamURL = sourceFile['data'];

            if (sourceMeta['isStreamable'] != null &&
                !sourceMeta['isStreamable']) {
              print("Link is not streamable.");
              return;
            }

            try {
              Uri.parse(sourceStreamURL);
            } catch (ex) {
              print("Invalid URL: $sourceStreamURL (${ex.toString()})");
              return;
            }

            // Initialize HttpClient and response...
            HttpClient httpClient = HttpClient();
            HttpClientResponse htmlResponse;
            // Measure epoch time in milliseconds (to determine ping).
            int preRequest = new DateTime.now().millisecondsSinceEpoch;

            try {
              htmlResponse =
              await httpClient.getUrl(Uri.parse(sourceStreamURL)).then((
                  HttpClientRequest request) {
                request.headers.add('Range', 'bytes=0-125000');
                request.followRedirects = true;
                return request.close();
              }).timeout(
                  Duration(seconds: 10),
                  onTimeout: () => null
              );
            } catch (ex) {
              print("Error checking stream data: $sourceStreamURL (${ex
                  .toString()})");
              return;
            }

            httpClient.close();

            if (htmlResponse == null) {
              print("Request to check $sourceStreamURL timed out.");
              event['metadata']['ping'] =
              null; // Making this null, should we choose to allow such requests in future.
              return;
            } else {
              int ping = (new DateTime.now().millisecondsSinceEpoch -
                  preRequest);
              if (htmlResponse.statusCode >= 400) {
                print(
                    "Request statusCode >= 400, therefore discarding. ($sourceStreamURL)");
                return;
              }

              event['metadata']['ping'] = ping;
            }

            addSource(SourceModel.fromJSON(event));

            if (pendingScrapes < 1) {
              _doneProcessing();
            }
            break;

          ///
          /// Once Claws has finished searching for a stream, it will return the
          /// 'done' event.
          ///
          /// REMEMBER: This does not take into account scrape results as those
          /// can be sent by the client at any time.
          ///
          case 'done':
            print("-- Server done! --");

            if (pendingScrapes < 1
                // (We don't want to call done twice.)
                && status == VendorServiceStatus.PROCESSING) {
              _doneProcessing();
            }
            break;

          default:
            print("An unexpected event was received: " + eventName);
        }
      } catch(ex) {
        print("Guys, David did something stupid: " + ex.toString());
      }

    }, onError: (error){
      this.setStatus(context, VendorServiceStatus.IDLE);
      Interface.showSimpleErrorDialog(context, title: "Scraping failed...", reason: "An error occurred whilst communicating with Claws.");
      print("An error occurred whilst communicating with Claws... (${error.toString()})");
      return;
    });

    // Add the data to the socket client (thus commanding the server to begin.)
    _webSocket.add(data);
  }

  _doneProcessing(){
    print("-- Client done! --");
  }

  ///////////////////////////////
  /// CLAWS UTILITY FUNCTIONS ///
  ///////////////////////////////

  Future<String> _generateClawsHash(String clawsClientKey, DateTime now) async {
    final randGen = Random.secure();

    Uint8List ivBytes = Uint8List.fromList(new List.generate(8, (_) => randGen.nextInt(128)));
    String ivHex = formatBytesAsHexString(ivBytes);
    String iv = Convert.utf8.decode(ivBytes);

    final key = clawsClientKey.substring(0, 32);
    final encrypter = new Encrypter(new Salsa20(key, iv));
    num time = (now.millisecondsSinceEpoch / 1000).floor();
    final plainText = "$time|$clawsClientKey";
    final encryptedText = encrypter.encrypt(plainText);

    return "$ivHex|$encryptedText";
  }

  String formatBytesAsHexString(Uint8List bytes) {
    var result = StringBuffer();
    for (var i = 0; i < bytes.lengthInBytes; i++) {
      var part = bytes[i];
      result.write('${part < 16 ? '0' : ''}${part.toRadixString(16)}');
    }
    return result.toString();
  }

  String base64UrlDecode(String str) {
    String output = str.replaceAll("-", "+").replaceAll("_", "/");
    switch (output.length % 4) {
      case 0:
        break;
      case 2:
        output += "==";
        break;
      case 3:
        output += "=";
        break;
      default:
        throw "Illegal base64url string!";
    }

    try {
      return Uri.decodeFull(Convert.utf8.decode(Convert.base64Url.decode(output)));
    } catch (err) {
      return Convert.utf8.decode(Convert.base64Url.decode(output));
    }
  }

  dynamic jwtDecode(token) {
    try {
      return Convert.jsonDecode(base64UrlDecode(token.split('.')[1]));
    } catch (e) {
      throw "Invalid token specified: " + e.message;
    }
  }

}