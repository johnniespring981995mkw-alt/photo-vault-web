import 'dart:typed_data';
import 'dart:convert'; // Để xử lý utf8
import 'dart:math'; // Để lấy lớp Random làm seed IV
import 'dart:ui'; // Để dùng BackdropFilter/ImageFilter
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

// Thư viện mã hóa SHA-256
import 'package:crypto/crypto.dart'; 

// Amplify Packages
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:amplify_auth_cognito/amplify_auth_cognito.dart';
import 'package:amplify_storage_s3/amplify_storage_s3.dart';
import 'package:amplify_authenticator/amplify_authenticator.dart';

import 'amplify_outputs.dart'; 

// Packages hỗ trợ
import 'package:image_picker/image_picker.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:image/image.dart' as img; // Thay thế flutter_image_compress bằng image thuần Dart

// Helper tải ảnh đa nền tảng
import 'download_helper.dart';

void main() {
  runApp(const MyApp());
}

// --- LỚP MÃ HÓA (DYNAMIC KEY TỪ PIN) ---
class MyEncryptor {
  // Key không còn cố định nữa mà sẽ được sinh ra từ PIN
  static encrypt.Key? _key; 
  static final _iv = encrypt.IV(Uint8List(16));

  // Hàm thiết lập PIN: Băm PIN thành Key 32-byte (256-bit)
  static void setPin(String pin) {
    final bytes = utf8.encode(pin);
    // SHA-256 luôn trả về 32 bytes, hoàn hảo cho AES-256
    final digest = sha256.convert(bytes); 
    _key = encrypt.Key(Uint8List.fromList(digest.bytes));
  }

  static void clearKey() {
    _key = null;
  }

  static Uint8List encryptData(List<int> bytes) {
    if (_key == null) throw Exception('Chưa nhập mã PIN bảo mật!');
    
    // Sinh IV ngẫu nhiên bảo mật (16 bytes)
    final iv = encrypt.IV.fromLength(16);
    
    // Sử dụng AES-CTR (SIC) không padding làm chuẩn bảo mật cao và hiệu năng tốt
    final encrypter = encrypt.Encrypter(encrypt.AES(_key!, mode: encrypt.AESMode.sic, padding: null));
    final encrypted = encrypter.encryptBytes(bytes, iv: iv);
    
    // Ghép IV (16 bytes) vào đầu ciphertext để lưu trữ tự chứa (self-contained)
    final output = Uint8List(16 + encrypted.bytes.length);
    output.setRange(0, 16, iv.bytes);
    output.setRange(16, output.length, encrypted.bytes);
    
    print("MÃ HÓA: Đã tạo file với IV ngẫu nhiên prepended. IV (Base64) = ${iv.base64}");
    return output;
  }

  static List<int> decryptData(List<int> bytes) {
    if (_key == null) throw Exception('Chưa nhập mã PIN bảo mật!');

    // Cách 1: Thử định dạng có IV đi kèm (16 byte đầu là IV, phần còn lại là ciphertext)
    if (bytes.length > 16) {
      try {
        final ivBytes = Uint8List.fromList(bytes.sublist(0, 16));
        final iv = encrypt.IV(ivBytes);
        final ciphertextBytes = Uint8List.fromList(bytes.sublist(16));
        
        final encrypter = encrypt.Encrypter(encrypt.AES(_key!, mode: encrypt.AESMode.sic, padding: null));
        final decrypted = encrypter.decryptBytes(encrypt.Encrypted(ciphertextBytes), iv: iv);
        
        // Kiểm tra xem có đúng định dạng ảnh hợp lệ không (JPEG, PNG, WebP, GIF)
        if (decrypted.length >= 3) {
          final h0 = decrypted[0];
          final h1 = decrypted[1];
          final h2 = decrypted[2];
          // JPEG: FF D8 FF
          // PNG: 89 50 4E
          // WebP/RIFF: 52 49 46 (R I F)
          // GIF: 47 49 46 (G I F)
          if ((h0 == 0xFF && h1 == 0xD8 && h2 == 0xFF) ||
              (h0 == 0x89 && h1 == 0x50 && h2 == 0x4E) ||
              (h0 == 0x52 && h1 == 0x49 && h2 == 0x46) ||
              (h0 == 0x47 && h1 == 0x49 && h2 == 0x46)) {
            print("GIẢI MÃ THÀNH CÔNG: Định dạng có IV đi kèm (16-byte prepended). IV (Base64) = ${iv.base64}");
            return decrypted;
          }
        }
      } catch (e) {
        print("Thử giải mã định dạng có IV đi kèm thất bại: $e. Sẽ thử định dạng cũ...");
      }
    }

    // Cách 2: Fallback giải mã định dạng cũ (không có IV đi kèm, IV mặc định toàn 0)
    print("GIẢI MÃ FALLBACK: Đang thử giải mã định dạng cũ (IV mặc định toàn 0)...");
    final defaultIv = encrypt.IV(Uint8List(16));
    
    // Thử giải mã không padding
    try {
      final encrypter = encrypt.Encrypter(encrypt.AES(_key!, mode: encrypt.AESMode.sic, padding: null));
      return encrypter.decryptBytes(encrypt.Encrypted(Uint8List.fromList(bytes)), iv: defaultIv);
    } catch (e) {
      // Thử giải mã với PKCS7 padding
      final encrypter = encrypt.Encrypter(encrypt.AES(_key!, mode: encrypt.AESMode.sic, padding: 'PKCS7'));
      return encrypter.decryptBytes(encrypt.Encrypted(Uint8List.fromList(bytes)), iv: defaultIv);
    }
  }


}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool _isAmplifyConfigured = false;

  @override
  void initState() {
    super.initState();
    _configureAmplify();
  }

  Future<void> _configureAmplify() async {
    try {
      final auth = AmplifyAuthCognito();
      final storage = AmplifyStorageS3();
      await Amplify.addPlugins([auth, storage]);
      await Amplify.configure(amplifyConfig);
      setState(() => _isAmplifyConfigured = true);
    } on Exception catch (e) {
      print('Lỗi cấu hình: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Authenticator(
      // Tùy chỉnh builder để chặn các bước cụ thể
      authenticatorBuilder: (BuildContext context, AuthenticatorState state) {
        // Nếu bước hiện tại là yêu cầu đổi mật khẩu mới (NEW_PASSWORD_REQUIRED)
        if (state.currentStep == AuthenticatorStep.confirmSignInNewPassword) {
          return CustomChangePasswordScreen(state: state);
        }
        // Các bước khác (SignIn, SignUp...) dùng giao diện mặc định của Amplify
        return null;
      },
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: Brightness.light,
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.teal,
            foregroundColor: Colors.white,
          ),
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: Brightness.dark,
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF004D40), // Deep teal background in dark mode
            foregroundColor: Colors.white,
          ),
        ),
        themeMode: ThemeMode.system, // Tự động đổi Light/Dark Mode theo hệ thống
        builder: Authenticator.builder(),
        // Sau khi đăng nhập AWS xong -> Vào màn hình nhập PIN
        home: _isAmplifyConfigured
            ? const PinLoginScreen() 
            : const Scaffold(body: Center(child: CircularProgressIndicator())),
      ),
    );
  }
}

// --- MÀN HÌNH ĐỔI MẬT KHẨU LẦN ĐẦU ---
class CustomChangePasswordScreen extends StatefulWidget {
  final AuthenticatorState state;
  const CustomChangePasswordScreen({super.key, required this.state});

  @override
  State<CustomChangePasswordScreen> createState() => _CustomChangePasswordScreenState();
}

class _CustomChangePasswordScreenState extends State<CustomChangePasswordScreen> {
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _isLoading = false;
  String? _error;

  Future<void> _submitNewPassword() async {
    final pass = _passwordController.text;
    final confirm = _confirmController.text;

    if (pass.isEmpty || confirm.isEmpty) {
      setState(() => _error = "Vui lòng nhập đầy đủ thông tin");
      return;
    }
    if (pass != confirm) {
      setState(() => _error = "Mật khẩu xác nhận không khớp");
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Gọi hàm của Amplify để xác nhận mật khẩu mới trực tiếp qua Auth API
      await Amplify.Auth.confirmSignIn(confirmationValue: pass);
    } on Exception catch (e) {
      setState(() {
        _error = "Lỗi: ${e.toString()}";
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [const Color(0xFF0F2027), const Color(0xFF203A43), const Color(0xFF2C5364)] // Sleek slate dark gradient
                : [const Color(0xFFE0F2F1), const Color(0xFF80CBC4), const Color(0xFF4DB6AC)], // Fresh teal light gradient
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            child: Card(
              margin: const EdgeInsets.all(24),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_reset, size: 64, color: theme.colorScheme.primary),
                    const SizedBox(height: 16),
                    const Text(
                      "Cần Đổi Mật Khẩu",
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      "Đây là lần đăng nhập đầu tiên.\nVui lòng thiết lập mật khẩu mới.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _passwordController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: "Mật khẩu mới",
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.lock),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _confirmController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: "Xác nhận mật khẩu",
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.lock_outline),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                    ],
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _submitNewPassword,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: theme.colorScheme.primary,
                          foregroundColor: theme.colorScheme.onPrimary,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: _isLoading
                            ? CircularProgressIndicator(color: theme.colorScheme.onPrimary)
                            : const Text("XÁC NHẬN ĐỔI MẬT KHẨU"),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => Amplify.Auth.signOut(), // Cho phép hủy để đăng nhập lại user khác
                      child: const Text("Quay lại đăng nhập"),
                    )
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- MÀN HÌNH NHẬP PIN MỚI ---
class PinLoginScreen extends StatefulWidget {
  const PinLoginScreen({super.key});

  @override
  State<PinLoginScreen> createState() => _PinLoginScreenState();
}

class _PinLoginScreenState extends State<PinLoginScreen> {
  final TextEditingController _pinController = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    // Xóa key cũ để đảm bảo an toàn khi logout/login lại
    MyEncryptor.clearKey();
  }

  void _submitPin() {
    final pin = _pinController.text.trim();
    if (pin.isEmpty) {
      setState(() => _error = "Vui lòng nhập mã PIN");
      return;
    }
    
    // Tạo khóa từ PIN và chuyển vào kho ảnh
    MyEncryptor.setPin(pin);
    
    Navigator.pushReplacement(
      context, 
      MaterialPageRoute(builder: (_) => const SecureGalleryScreen())
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [const Color(0xFF0F2027), const Color(0xFF203A43), const Color(0xFF2C5364)] // Slate dark gradient
                : [const Color(0xFFE0F2F1), const Color(0xFF80CBC4), const Color(0xFF4DB6AC)], // Teal light gradient
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            child: Card(
              margin: const EdgeInsets.all(24),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_outline, size: 64, color: theme.colorScheme.primary),
                    const SizedBox(height: 16),
                    const Text(
                      "Nhập Mã PIN Bảo Mật",
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      "Mã PIN này dùng để mã hóa ảnh của bạn.\nHãy ghi nhớ nó kỹ!",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _pinController,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: "Mã PIN",
                        border: const OutlineInputBorder(),
                        errorText: _error,
                        prefixIcon: const Icon(Icons.key),
                      ),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _submitPin,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: theme.colorScheme.primary,
                          foregroundColor: theme.colorScheme.onPrimary,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: const Text("MỞ KHO ẢNH"),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => Amplify.Auth.signOut(),
                      child: const Text("Đăng xuất tài khoản AWS"),
                    )
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- KHO ẢNH ---
class SecureGalleryScreen extends StatefulWidget {
  const SecureGalleryScreen({super.key});

  @override
  State<SecureGalleryScreen> createState() => _SecureGalleryScreenState();
}

class _SecureGalleryScreenState extends State<SecureGalleryScreen> {
  List<StorageItem> _thumbFiles = [];
  bool _isLoading = true;
  final ImagePicker _picker = ImagePicker();
  String? _userId;
  bool _isUploading = false;
  double _uploadProgress = 0.0;
  String _uploadStatus = "";

  @override
  void initState() {
    super.initState();
    _initUserPath();
  }

  Future<void> _initUserPath() async {
    try {
      final session = await Amplify.Auth.fetchAuthSession() as CognitoAuthSession;
      _userId = session.identityIdResult.value;
      if (mounted) _fetchFiles();
    } catch (e) {
      print('Lỗi Auth: $e');
    }
  }

  Future<void> _fetchFiles() async {
    if (_userId == null) return;
    setState(() => _isLoading = true);
    try {
      final path = 'thumb/$_userId/';
      final result = await Amplify.Storage.list(
        path: StoragePath.fromString(path),
        options: const StorageListOptions(pageSize: 1000),
      ).result;
      
      final items = result.items;
      print("DANH SÁCH S3: Đã tìm thấy ${items.length} tệp tin trong thư mục $path");
      for (var item in items) {
        print("  - Tệp: ${item.path} (Sửa đổi lần cuối: ${item.lastModified})");
      }
      
      items.sort((a, b) => b.lastModified!.compareTo(a.lastModified!));
      
      setState(() {
        _thumbFiles = items;
        _isLoading = false;
      });

    } catch (e) {
      print("Lỗi khi tải danh sách tệp S3: $e");
      setState(() => _isLoading = false);
    }
  }

  Future<void> _uploadEncryptedImage() async {
    if (_userId == null) return;
    final List<XFile> images = await _picker.pickMultiImage();
    if (images.isEmpty) return;

    setState(() {
      _isUploading = true;
      _uploadProgress = 0.0;
      _uploadStatus = "Đang bắt đầu tải lên ${images.length} ảnh...";
    });

    int successCount = 0;
    for (int i = 0; i < images.length; i++) {
      final image = images[i];
      setState(() {
        _uploadProgress = i / images.length;
        _uploadStatus = "Đang mã hóa & tải lên ảnh ${i + 1}/${images.length}...";
      });

      try {
        final String fileId = '${DateTime.now().millisecondsSinceEpoch}_${image.name.hashCode}_$i';
        final String fileName = 'img_$fileId.enc';

        // 1. Mã hóa & Upload Full (Sử dụng key từ PIN và lưu trữ trực tiếp bằng Bytes)
        final originalBytes = await image.readAsBytes();
        final encryptedFullBytes = MyEncryptor.encryptData(originalBytes);
        
        await Amplify.Storage.uploadData(
          data: StorageDataPayload.bytes(encryptedFullBytes),
          path: StoragePath.fromString('full/$_userId/$fileName'),
        ).result;

        // 2. Mã hóa & Upload Thumb (Sử dụng thư viện 'image' thuần Dart)
        final decodedImage = img.decodeImage(originalBytes);
        List<int> compressedBytes;
        if (decodedImage != null) {
          // Tạo ảnh thumbnail hình vuông 200x200 bằng cách resize và crop để giữ nguyên tỷ lệ (aspect ratio) không bị méo ảnh
          final thumbnail = img.copyResizeCropSquare(decodedImage, size: 200);
          compressedBytes = img.encodeJpg(thumbnail, quality: 50);
        } else {
          compressedBytes = originalBytes;
        }
        
        final encryptedThumbBytes = MyEncryptor.encryptData(compressedBytes);
        
        await Amplify.Storage.uploadData(
          data: StorageDataPayload.bytes(encryptedThumbBytes),
          path: StoragePath.fromString('thumb/$_userId/$fileName'),
        ).result;

        successCount++;
      } catch (e) {
        print('Lỗi upload file ${image.name}: $e');
      }
    }

    setState(() {
      _uploadProgress = 1.0;
      _uploadStatus = "Đã hoàn thành! Đã tải lên $successCount/${images.length} ảnh.";
    });

    await Future.delayed(const Duration(milliseconds: 850));

    if (mounted) {
      setState(() {
        _isUploading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Đã sao lưu an toàn $successCount/${images.length} ảnh!')),
      );
      _fetchFiles();
    }
  }

  @override
  Widget build(BuildContext context) {
    final imageCount = _thumbFiles.where((item) => !item.path.endsWith('/')).length;
    return Scaffold(
      appBar: AppBar(
        title: Text('Kho Ảnh Bí Mật ($imageCount)'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _fetchFiles),
          // Khi logout thì quay về màn hình đăng nhập AWS
          IconButton(
            icon: const Icon(Icons.logout), 
            onPressed: () {
              MyEncryptor.clearKey(); // Xóa PIN khỏi bộ nhớ
              Amplify.Auth.signOut();
            }
          ),
        ],
      ),
      body: Stack(
        children: [
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _thumbFiles.isEmpty
                  ? const Center(child: Text('Chưa có ảnh nào.'))
                  : GridView.builder(
                      padding: const EdgeInsets.all(8),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3, crossAxisSpacing: 8, mainAxisSpacing: 8,
                      ),
                      itemCount: _thumbFiles.length,
                      itemBuilder: (context, index) {
                        final item = _thumbFiles[index];
                        if (item.path.endsWith('/')) return const SizedBox.shrink();

                        return GestureDetector(
                          onTap: () {
                            final fullPath = item.path.replaceFirst('thumb/', 'full/');
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => DecryptViewerScreen(
                                  fullPath: fullPath,
                                  date: item.lastModified,
                                ),
                              ),
                            ).then((value) {
                              if (value == true) {
                                _fetchFiles();
                              }
                            });
                          },
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: EncryptedThumbnail(storagePath: item.path),
                          ),
                        );
                      },
                    ),
          if (_isUploading)
            Positioned.fill(
              child: ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 5.0, sigmaY: 5.0),
                  child: Container(
                    color: Colors.black.withOpacity(0.55),
                    child: Center(
                      child: Card(
                        margin: const EdgeInsets.symmetric(horizontal: 32),
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(color: Colors.teal),
                              const SizedBox(height: 24),
                              Text(
                                _uploadStatus,
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 16),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: LinearProgressIndicator(
                                  value: _uploadProgress,
                                  minHeight: 8,
                                  backgroundColor: Colors.grey.withOpacity(0.2),
                                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.teal),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '${(_uploadProgress * 100).toInt()}%',
                                style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _uploadEncryptedImage,
        label: const Text('Thêm ảnh'),
        icon: const Icon(Icons.add_a_photo),
      ),
    );
  }

class EncryptedThumbnail extends StatefulWidget {
  final String storagePath;
  const EncryptedThumbnail({super.key, required this.storagePath});

  @override
  State<EncryptedThumbnail> createState() => _EncryptedThumbnailState();
}

class _EncryptedThumbnailState extends State<EncryptedThumbnail> {
  Uint8List? _imageBytes;
  
  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    try {
      final result = await Amplify.Storage.downloadData(
        path: StoragePath.fromString(widget.storagePath),
      ).result;

      final encryptedBytes = result.bytes;
      print("Đã tải: ${widget.storagePath}, độ dài: ${encryptedBytes.length} bytes");


      // Giải mã bằng Key từ PIN hiện tại
      final decryptedData = MyEncryptor.decryptData(encryptedBytes);
      print("Giải mã xong: ${widget.storagePath}, độ dài: ${decryptedData.length} bytes");
      if (mounted) setState(() => _imageBytes = Uint8List.fromList(decryptedData));
    } catch (e) {
      // Nếu PIN sai, giải mã sẽ thất bại và không hiện ảnh
      print("Giải mã thumbnail thất bại (${widget.storagePath}): $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_imageBytes == null) return Container(
      color: Colors.grey[300], 
      child: const Icon(Icons.lock_clock, color: Colors.grey)
    );
    return Image.memory(
      _imageBytes!, 
      fit: BoxFit.cover, 
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) {
        return Container(
          color: Colors.grey[200],
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock, color: Colors.red),
              SizedBox(height: 4),
              Text("Sai PIN", style: TextStyle(color: Colors.red, fontSize: 10, fontWeight: FontWeight.bold)),
            ],
          ),
        );
      },
    );
  }
}

class DecryptViewerScreen extends StatefulWidget {
  final String fullPath;
  final DateTime? date;
  const DecryptViewerScreen({super.key, required this.fullPath, this.date});

  @override
  State<DecryptViewerScreen> createState() => _DecryptViewerScreenState();
}

class _DecryptViewerScreenState extends State<DecryptViewerScreen> {
  Uint8List? _fullImageBytes;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadFullImage();
  }

  Future<void> _loadFullImage() async {
    try {
      final result = await Amplify.Storage.downloadData(
        path: StoragePath.fromString(widget.fullPath),
      ).result;

      final encryptedBytes = result.bytes;
      print("Đã tải ảnh gốc: ${widget.fullPath}, độ dài: ${encryptedBytes.length} bytes");
      // Giải mã bằng Key từ PIN
      final decryptedData = MyEncryptor.decryptData(encryptedBytes);
      print("Giải mã ảnh gốc xong: ${widget.fullPath}, độ dài: ${decryptedData.length} bytes");

      if (mounted) {
        setState(() {
          _fullImageBytes = Uint8List.fromList(decryptedData);
          _loading = false;
        });
      }
    } catch (e) {
      print("Giải mã ảnh gốc thất bại (${widget.fullPath}): $e");
      if (mounted) {
        setState(() {
          _loading = false;
          _error = "Không thể giải mã! Có thể bạn đã nhập sai mã PIN so với lúc upload. Chi tiết: $e";
        });
      }
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xóa vĩnh viễn?'),
        content: const Text('Ảnh sẽ bị xóa khỏi cloud.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Xóa', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm == true && mounted) _deleteFiles(context);
  }

  Future<void> _deleteFiles(BuildContext context) async {
    try {
      showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
      
      await Amplify.Storage.remove(path: StoragePath.fromString(widget.fullPath)).result;
      final thumbPath = widget.fullPath.replaceFirst('full/', 'thumb/');
      try {
        await Amplify.Storage.remove(path: StoragePath.fromString(thumbPath)).result;
      } catch (_) {}

      if(mounted) {
        Navigator.pop(context); // Đóng Loading Dialog
        Navigator.pop(context, true); // Đóng DecryptViewerScreen và trả về true
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã xóa.')));
      }
    } catch (e) {
      if(mounted) Navigator.pop(context);
    }
  }

  Future<void> _saveToGallery() async {
    if (_fullImageBytes == null) return;
    try {
      final String fileId = '${DateTime.now().millisecondsSinceEpoch}';
      final String fileName = 'img_$fileId.jpg';
      
      // Gọi helper đa nền tảng hỗ trợ tải xuống
      await saveImage(_fullImageBytes!, fileName);
      
      if(mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đã lưu ảnh về máy!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi khi tải ảnh: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(icon: const Icon(Icons.delete), onPressed: () => _confirmDelete(context)),
          IconButton(icon: const Icon(Icons.download), onPressed: _saveToGallery),
        ],
      ),
      body: Center(
        child: _loading
            ? const CircularProgressIndicator(color: Colors.white)
            : _error != null 
                ? Padding(padding: const EdgeInsets.all(20), child: Text(_error!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center))
                : _fullImageBytes != null 
                  ? InteractiveViewer(
                      child: Image.memory(
                        _fullImageBytes!,
                        errorBuilder: (context, error, stackTrace) {
                          return const Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.lock, color: Colors.red, size: 64),
                              SizedBox(height: 16),
                              Text(
                                "Không thể giải mã hình ảnh này!\nCó thể bạn đã nhập sai mã PIN so với lúc mã hóa tệp tin.",
                                style: TextStyle(color: Colors.red, fontSize: 16),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          );
                        },
                      ),
                    )
                  : const SizedBox(),
      ),
    );
  }
}

// Ghi đè hàm print để ẩn toàn bộ log trong console theo yêu cầu
void print(Object? object) {
  // Không làm gì cả để loại bỏ toàn bộ console logs
}
