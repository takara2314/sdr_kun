import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_full_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/return_code.dart';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:logger/logger.dart';
import 'package:external_path/external_path.dart';

const String appName = 'sdr_kun';

final _logger = Logger(
  printer: PrettyPrinter(
    methodCount: 0,  // スタックトレースを表示しない
    dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart, // タイムスタンプを表示
    colors: true,    // カラー出力を有効化
  ),
);

void main() {
  _logger.i('アプリケーションを起動しました');
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'HDR to SDR 変換',
      home: HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  HomeScreenState createState() => HomeScreenState();
}

class FFmpegProgress {
  final int? frame;
  final double? fps;
  final double? q;
  final String? size;
  final String? time;
  final String? bitrate;
  final double? speed;

  FFmpegProgress({
    this.frame,
    this.fps,
    this.q,
    this.size,
    this.time,
    this.bitrate,
    this.speed,
  });
}

class HomeScreenState extends State<HomeScreen> {
  String _progress = '準備完了';
  String? _selectedFilePath;
  String? _outputPath;
  bool _isConverting = false;
  FFmpegSession? _currentSession;
  double _progressPercent = 0.0;
  String? _totalDuration;

  // FFmpegコマンドのオプションを定数として定義
  static const Map<String, String> FFMPEG_OPTIONS = {
    'max_width': '1920',      // Twitter動画の最大幅制限
    'max_height': '1200',     // Twitter動画の最大高さ制限
    'framerate': '40',        // Twitter動画の最大フレームレート制限
    'maxrate': '25M',         // Twitter動画の最大ビットレート制限
    'bufsize': '25M',         // バッファサイズ（ビットレート制限に合わせる）
    'crf': '23',             // 品質設定（低いほど高品質、推奨値は23）
    'preset': 'slow',        // エンコード設定（低速だが高品質）
  };

  // HDR to SDR変換用のフィルターチェーンを構築する関数
  String _buildHDRtoSDRFilter() {
    return [
      'zscale=t=linear:npl=100',        // リニア色空間に変換
      'format=gbrpf32le',               // 32bit浮動小数点形式に変換
      'zscale=p=bt709',                 // BT.709色空間にスケーリング
      'tonemap=tonemap=hable:desat=0',  // HDRからSDRへのトーンマッピング（Hableアルゴリズム）
      'zscale=t=bt709:m=bt709:r=tv',   // BT.709色空間で出力
      'format=yuv420p',                 // 標準的な動画フォーマットに変換
      // 解像度制限に適合するようにスケーリング
      'scale=\'min(${FFMPEG_OPTIONS["max_width"]},iw)\':\'min(${FFMPEG_OPTIONS["max_height"]},ih)\':force_original_aspect_ratio=decrease',
      // 幅と高さを2の倍数に調整
      'pad=width=ceil(iw/2)*2:height=ceil(ih/2)*2',
    ].join(',');
  }

  // FFmpegのコマンドを構築する関数
  String _buildFFmpegCommand(String inputPath, String outputPath) {
    final options = [
      '-i "$inputPath"',                          // 入力ファイル
      '-vf "${_buildHDRtoSDRFilter()}"',         // ビデオフィルター
      '-r ${FFMPEG_OPTIONS['framerate']}',       // フレームレート設定
      '-c:v libx264',                            // H.264エンコーダーを使用
      '-crf ${FFMPEG_OPTIONS['crf']}',           // 品質設定
      '-preset ${FFMPEG_OPTIONS['preset']}',     // エンコード設定
      '-maxrate ${FFMPEG_OPTIONS['maxrate']}',   // 最大ビットレート
      '-bufsize ${FFMPEG_OPTIONS['bufsize']}',   // バッファサイズ
      '-c:a copy',                               // 音声はそのままコピー
      '"$outputPath"',                           // 出力ファイル
    ];

    return options.join(' ');
  }

  @override
  void initState() {
    super.initState();
    _logger.d('ホーム画面を初期化しています');
    _requestPermissions();
  }

  // 進捗状況を表示するSnackBarを表示する関数
  void _showProgressSnackBar(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.only(
          bottom: MediaQuery.of(context).size.height - 100,
          left: 20,
          right: 20,
        ),
      ),
    );
  }

  Future<void> _requestPermissions() async {
    _logger.i('必要な権限をリクエストしています');
    Map<Permission, PermissionStatus> statuses = await [
      Permission.videos,
      Permission.storage,
    ].request();

    if (statuses[Permission.videos] == PermissionStatus.granted) {
      _logger.i('動画ファイルへの読み取りアクセス許可が付与されました');
    } else {
      _logger.w('動画ファイルへの読み取りアクセス許可が拒否されました');
    }

    if (Platform.isAndroid) {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      _logger.d('Android SDK バージョン: ${androidInfo.version.sdkInt}');
      if (androidInfo.version.sdkInt <= 29) {
        if (statuses[Permission.storage] == PermissionStatus.granted) {
          _logger.i('外部ストレージへの書き込みアクセス許可が付与されました');
        } else {
          _logger.w('外部ストレージへの書き込みアクセス許可が拒否されました');
        }
      }
    }
  }

  // FFmpegのコマンド実行関数
  Future<void> _runFFmpegCommand() async {
    final String inputPath = _selectedFilePath!;
    final String outputPath = _outputPath!;

    _logger.i('FFmpegコマンドを実行開始します');
    String command = _buildFFmpegCommand(inputPath, outputPath);

    _logger.d('実行コマンド: $command');
    _currentSession = await FFmpegKit.executeAsync(command, (session) async {
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        _logger.i('FFmpeg処理が正常に完了しました');
        if (mounted) {
          setState(() {
            _progress = '完了';
            _isConverting = false;
          });
        }
        _logger.i('動画を保存しました: $outputPath');
        _showProgressSnackBar('変換が完了しました');
      } else {
        final failStackTrace = await session.getFailStackTrace();
        _logger.e('FFmpeg処理でエラーが発生しました', error: failStackTrace);
        if (mounted) {
          setState(() {
            _progress = 'エラー: $failStackTrace';
            _isConverting = false;
          });
        }
        _showProgressSnackBar('エラーが発生しました');
      }
    }, (log) {
      final message = log.getMessage();
      _logger.d('FFmpegログ: $message');
      if (mounted) {
        setState(() {
          final progress = _parseFFmpegProgress(message);
          if (progress != null) {
            _progress = '''
フレーム数: ${progress.frame}
FPS: ${progress.fps?.toStringAsFixed(1)}
品質: ${progress.q?.toStringAsFixed(1)}
サイズ: ${progress.size}
現在位置: ${progress.time}
ビットレート: ${progress.bitrate}
処理速度: ${progress.speed?.toStringAsFixed(2)}x
''';
          } else {
            _progress = message;
          }
        });
      }
    }, (statistics) {
      // 統計情報を処理
      if (mounted) {
        setState(() {
          _progress = '進行中... ${statistics.getTime() / 1000}秒経過';
        });
      }
    });
  }

  // キャンセル処理を追加
  Future<void> _cancelConversion() async {
    if (_currentSession != null) {
      _logger.i('変換処理をキャンセルします');
      await _currentSession!.cancel();
      setState(() {
        _progress = 'キャンセルされました';
        _isConverting = false;
      });
      _showProgressSnackBar('変換をキャンセルしました');
    }
  }

  // 変換処理を開始する関数
  Future<void> _startConversion() async {
    if (_selectedFilePath == null) {
      _logger.w('動画ファイルが選択されていません');
      setState(() {
        _progress = '動画ファイルが選択されていません';
      });
      _showProgressSnackBar('動画ファイルが選択されていません');
      return;
    }

    if (_isConverting) {
      _showProgressSnackBar('すでに変換処理が実行中です');
      return;
    }

    // 出力ディレクトリの取得
    Directory directory;
    if (Platform.isAndroid) {
      // Picturesのパスを取得
      final picturesPath = await ExternalPath.getExternalStoragePublicDirectory(
        ExternalPath.DIRECTORY_PICTURES,
      );
      // sdr_kunフォルダを作成
      final albumPath = '$picturesPath/sdr_kun';
      directory = await Directory(albumPath).create(recursive: true);
    } else {
      // iOSの場合
      final appDir = await getApplicationDocumentsDirectory();
      directory = Directory(path.join(appDir.path, 'sdr_kun'));
      await directory.create(recursive: true);
    }

    // 入力ファイル名から出力ファイル名を生成
    final inputFileName = path.basename(_selectedFilePath!);
    String outputFileName = 'SDR_$inputFileName';
    String baseOutputPath = path.join(directory.path, outputFileName);
    _outputPath = baseOutputPath;

    // ファイルが存在する場合は、連番を付与
    int counter = 1;
    while (await File(_outputPath!).exists()) {
      final extension = path.extension(baseOutputPath);
      final nameWithoutExtension = path.basenameWithoutExtension(baseOutputPath);
      _outputPath = path.join(
        directory.path,
        '${nameWithoutExtension}_$counter$extension',
      );
      counter++;
    }

    _logger.d('出力ファイルパス: $_outputPath');

    setState(() {
      _isConverting = true;
    });

    // 変換処理を開始
    await _runFFmpegCommand();
  }

  // ファイル選択
  Future<void> _pickFile() async {
    if (_isConverting) {
      _showProgressSnackBar('変換処理中は新しいファイルを選択できません');
      return;
    }

    _logger.i('ファイル選択を開始します');
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.video,
    );

    if (result != null) {
      _logger.i('ファイルが選択されました: ${result.files.single.path}');
      setState(() {
        _selectedFilePath = result.files.single.path!;
        _progress = 'ファイルが選択されました: $_selectedFilePath';
        _totalDuration = null; // 新しいファイルが選択されたらリセット
      });

      // 動画の長さを取得
      final ffprobeCommand = '-hide_banner -show_entries format "${result.files.single.path}"';
      _logger.d('動画情報取得コマンド: $ffprobeCommand');

      await FFprobeKit.execute(ffprobeCommand).then((session) async {
        final output = await session.getOutput();
        _logger.d('FFprobeログ: $output');

        final durationRegex = RegExp(r'duration=(\d+\.\d+)');
        final match = durationRegex.firstMatch(output ?? '');
        if (match != null) {
          final durationSeconds = double.parse(match.group(1)!);
          final hours = (durationSeconds ~/ 3600).toString().padLeft(2, '0');
          final minutes = ((durationSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
          final seconds = ((durationSeconds % 60).toStringAsFixed(2)).padLeft(5, '0');

          setState(() {
            _totalDuration = '$hours:$minutes:$seconds';
            _logger.i('動画の長さ: $_totalDuration');
          });
        }
      });

      _showProgressSnackBar('ファイルが選択されました');
    } else {
      _logger.w('ファイル選択がキャンセルされました');
      setState(() {
        _progress = 'ファイル選択がキャンセルされました';
      });
      _showProgressSnackBar('ファイル選択がキャンセルされました');
    }
  }

  // FFmpegのログをパースする関数
  FFmpegProgress? _parseFFmpegProgress(String log) {
    final RegExp progressRegex = RegExp(
      r'frame=\s*(\d+)\s*fps=\s*(\d+\.?\d*)\s*q=\s*(\d+\.?\d*)\s*size=\s*(\d+.*?kB)\s*time=\s*(\d{2}:\d{2}:\d{2}\.\d{2})\s*bitrate=\s*(\d+\.?\d*kbits/s)(?:\s*dup=\d+\s*drop=\d+)?\s*speed=\s*(\d+\.?\d*)x'
    );

    final match = progressRegex.firstMatch(log);
    if (match != null) {
      // 現在の処理時間から進捗率を計算
      final currentTime = match.group(5);
      if (currentTime != null && _totalDuration != null) {
        final current = _parseTimeToSeconds(currentTime);
        final total = _parseTimeToSeconds(_totalDuration!);
        if (total > 0) {
          setState(() {
            _progressPercent = current / total;
          });
        }
      }

      return FFmpegProgress(
        frame: int.tryParse(match.group(1) ?? ''),
        fps: double.tryParse(match.group(2) ?? ''),
        q: double.tryParse(match.group(3) ?? ''),
        size: match.group(4),
        time: match.group(5),
        bitrate: match.group(6),
        speed: double.tryParse(match.group(7) ?? ''),
      );
    }
    return null;
  }

  // 時間文字列を秒数に変換する関数を追加
  double _parseTimeToSeconds(String time) {
    final parts = time.split(':');
    if (parts.length == 3) {
      final hours = double.parse(parts[0]);
      final minutes = double.parse(parts[1]);
      final seconds = double.parse(parts[2]);
      return hours * 3600 + minutes * 60 + seconds;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SDRくん（HDR → SDR 変換）'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: _isConverting ? null : _pickFile,
              child: const Text('ファイルを選択'),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _isConverting ? null : _startConversion,
              child: const Text('変換開始'),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  if (_totalDuration != null) ...[
                    Text(
                      '動画の長さ: $_totalDuration',
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    const SizedBox(height: 8),
                    if (_isConverting) ...[
                      LinearProgressIndicator(
                        value: _progressPercent,
                        backgroundColor: Colors.grey[300],
                        valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${(_progressPercent * 100).toStringAsFixed(1)}%',
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ],
                  Text(
                    _progress,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ],
              ),
            ),
            if (_isConverting) ...[
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _cancelConversion,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                ),
                child: const Text('キャンセル'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
