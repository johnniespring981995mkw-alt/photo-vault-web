import 'dart:typed_data';
import 'dart:convert'; // Để xử lý utf8
import 'dart:math'; // Để lấy lớp Random làm seed IV
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
    print("MÃ HÓA: Key (Base64) = ${_key!.base64}, IV (Base64) = ${_iv.base64}");
    // Sử dụng PKCS7 padding làm mặc định để tương thích hoàn toàn hai chiều với Mobile
    final encrypter = encrypt.Encrypter(encrypt.AES(_key!, mode: encrypt.AESMode.sic, padding: 'PKCS7'));
    final encrypted = encrypter.encryptBytes(bytes, iv: _iv);
    return encrypted.bytes;
  }

  static List<int> decryptData(List<int> bytes) {
    if (_key == null) throw Exception('Chưa nhập mã PIN bảo mật!');
    print("GIẢI MÃ: Key (Base64) = ${_key!.base64}, IV (Base64) = ${_iv.base64}");
    
    // 1. Thử giải mã với PKCS7 padding (tương thích ảnh cũ trên Android và ảnh mới chuẩn)
    try {
      final encrypter = encrypt.Encrypter(encrypt.AES(_key!, mode: encrypt.AESMode.sic, padding: 'PKCS7'));
      final encrypted = encrypt.Encrypted(Uint8List.fromList(bytes));
      final decrypted = encrypter.decryptBytes(encrypted, iv: _iv);
      return decrypted;
    } catch (e) {
      print("Giải mã với PKCS7 padding thất bại: $e. Thử giải mã không padding (padding: null)...");
    }

    // 2. Thử giải mã không padding (tương thích các ảnh test đã upload ở các bước trước)
    final encrypter = encrypt.Encrypter(encrypt.AES(_key!, mode: encrypt.AESMode.sic, padding: null));
    final encrypted = encrypt.Encrypted(Uint8List.fromList(bytes));
    return encrypter.decryptBytes(encrypted, iv: _iv);
  }

  static void testDecrypt(Uint8List encryptedBytes, String filename) {
    if (_key == null) return;
    print("===== CHẠY THỬ NGHIỆM GIẢI MÃ CHO FILE: $filename =====");
    
    // Tìm các phần của tên file
    final nameWithoutExt = filename.split('.').first; // e.g. img_1766246583839_212824140
    final parts = nameWithoutExt.split('_');
    
    String timestamp = "";
    String suffix = "";
    if (parts.length >= 2) timestamp = parts[1];
    if (parts.length >= 3) suffix = parts[2];
    
    print("Parsed: timestamp = '$timestamp', suffix = '$suffix'");
    
    // Các loại IV cần test:
    final Map<String, encrypt.IV> ivs = {};
    
    // 1. IV toàn 0
    ivs["ALL_ZERO_IV"] = encrypt.IV(Uint8List(16));
    
    // 2. IV từ suffix (nếu có)
    if (suffix.isNotEmpty) {
      // 2a. Suffix dạng string bytes pad 0
      final suffixBytes = utf8.encode(suffix);
      final ivBytes = Uint8List(16);
      for (int i = 0; i < suffixBytes.length && i < 16; i++) {
        ivBytes[i] = suffixBytes[i];
      }
      ivs["SUFFIX_STRING_BYTES_PAD_0"] = encrypt.IV(ivBytes);
      
      // 2b. Suffix làm seed Random (byte-by-byte)
      final seed = int.tryParse(suffix);
      if (seed != null) {
        final random = Random(seed);
        final ivBytes = Uint8List.fromList(List.generate(16, (i) => random.nextInt(256)));
        ivs["SUFFIX_RANDOM_SEED_IV"] = encrypt.IV(ivBytes);
        
        // 2c. Suffix làm seed Random (uint32)
        final random2 = Random(seed);
        final byteData = ByteData(16);
        byteData.setUint32(0, random2.nextInt(0xFFFFFFFF));
        byteData.setUint32(4, random2.nextInt(0xFFFFFFFF));
        byteData.setUint32(8, random2.nextInt(0xFFFFFFFF));
        byteData.setUint32(12, random2.nextInt(0xFFFFFFFF));
        ivs["SUFFIX_RANDOM_SEED_UINT32_IV"] = encrypt.IV(byteData.buffer.asUint8List());
      }
      
      // 2d. MD5 của suffix string
      final md5Digest = md5.convert(utf8.encode(suffix));
      ivs["SUFFIX_MD5_IV"] = encrypt.IV(Uint8List.fromList(md5Digest.bytes));
      
      // 2e. SHA-256 của suffix string (cắt 16 bytes)
      final sha256Digest = sha256.convert(utf8.encode(suffix));
      ivs["SUFFIX_SHA256_IV"] = encrypt.IV(Uint8List.fromList(sha256Digest.bytes.sublist(0, 16)));
    }
    
    // 3. IV từ timestamp (nếu có)
    if (timestamp.isNotEmpty) {
      // 3a. Timestamp string bytes pad 0
      final tsBytes = utf8.encode(timestamp);
      final ivBytes = Uint8List(16);
      for (int i = 0; i < tsBytes.length && i < 16; i++) {
        ivBytes[i] = tsBytes[i];
      }
      ivs["TIMESTAMP_STRING_BYTES_PAD_0"] = encrypt.IV(ivBytes);
      
      // 3b. Timestamp làm seed Random (byte-by-byte)
      final seed = int.tryParse(timestamp);
      if (seed != null) {
        final random = Random(seed);
        final ivBytes = Uint8List.fromList(List.generate(16, (i) => random.nextInt(256)));
        ivs["TIMESTAMP_RANDOM_SEED_IV"] = encrypt.IV(ivBytes);
        
        // 3c. Timestamp làm seed Random (uint32)
        final random2 = Random(seed);
        final byteData = ByteData(16);
        byteData.setUint32(0, random2.nextInt(0xFFFFFFFF));
        byteData.setUint32(4, random2.nextInt(0xFFFFFFFF));
        byteData.setUint32(8, random2.nextInt(0xFFFFFFFF));
        byteData.setUint32(12, random2.nextInt(0xFFFFFFFF));
        ivs["TIMESTAMP_RANDOM_SEED_UINT32_IV"] = encrypt.IV(byteData.buffer.asUint8List());
      }
      
      // 3d. MD5 của timestamp string
      final md5Digest = md5.convert(utf8.encode(timestamp));
      ivs["TIMESTAMP_MD5_IV"] = encrypt.IV(Uint8List.fromList(md5Digest.bytes));
    }
    
    // 4. IV từ cả filename (không đuôi)
    final fnBytes = utf8.encode(nameWithoutExt);
    final fnIvBytes = Uint8List(16);
    for (int i = 0; i < fnBytes.length && i < 16; i++) {
      fnIvBytes[i] = fnBytes[i];
    }
    ivs["FILENAME_BYTES_PAD_0"] = encrypt.IV(fnIvBytes);
    
    final fnMd5 = md5.convert(utf8.encode(nameWithoutExt));
    ivs["FILENAME_MD5_IV"] = encrypt.IV(Uint8List.fromList(fnMd5.bytes));
    
    // Thử các loại Key khác nhau (SHA256 vs Padded raw bytes)
    final Map<String, encrypt.Key> keys = {
      "SHA256_KEY": _key!
    };
    
    // 5. Thêm các key candidate từ PIN
    final String knownPin = "888111";
    final pinBytes = utf8.encode(knownPin);
    
    // Key 1: Raw PIN padded to 32 bytes
    final keyBytes32 = Uint8List(32);
    for (int i = 0; i < pinBytes.length && i < 32; i++) {
      keyBytes32[i] = pinBytes[i];
    }
    keys["RAW_PIN_PAD_0_KEY_32"] = encrypt.Key(keyBytes32);
    
    // Key 2: Raw PIN padded to 16 bytes
    final keyBytes16 = Uint8List(16);
    for (int i = 0; i < pinBytes.length && i < 16; i++) {
      keyBytes16[i] = pinBytes[i];
    }
    keys["RAW_PIN_PAD_0_KEY_16"] = encrypt.Key(keyBytes16);
    
    // Key 3: MD5 of PIN
    final md5Pin = md5.convert(pinBytes);
    keys["MD5_PIN_KEY"] = encrypt.Key(Uint8List.fromList(md5Pin.bytes));

    final List<encrypt.AESMode> modes = [
      encrypt.AESMode.sic,
      encrypt.AESMode.cbc,
      encrypt.AESMode.cfb64,
      encrypt.AESMode.ofb64,
      encrypt.AESMode.ecb,
    ];
    
    // Chạy thử từng tổ hợp
    keys.forEach((keyName, keyVal) {
      ivs.forEach((ivName, ivVal) {
        for (final mode in modes) {
          for (var padding in ['PKCS7', null]) {
            try {
              final encrypter = encrypt.Encrypter(encrypt.AES(keyVal, mode: mode, padding: padding));
              final encrypted = encrypt.Encrypted(Uint8List.fromList(encryptedBytes));
              final decrypted = encrypter.decryptBytes(encrypted, iv: ivVal);
              
              final isJpeg = decrypted.length >= 3 && decrypted[0] == 0xFF && decrypted[1] == 0xD8 && decrypted[2] == 0xFF;
              final isPng = decrypted.length >= 4 && decrypted[0] == 0x89 && decrypted[1] == 0x50 && decrypted[2] == 0x4E && decrypted[3] == 0x47;
              
              if (isJpeg || isPng) {
                print(">>> KẾT QUẢ THÀNH CÔNG: Key = $keyName, IV = $ivName, Mode = ${mode.toString()}, Padding = $padding, Định dạng = ${isJpeg ? 'JPEG' : 'PNG'} !!!");
                print("First 10 bytes: ${decrypted.sublist(0, 10).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}");
              }
            } catch (e) {
              // bỏ qua lỗi
            }
          }
        }
      });
    });
    print("=================================================");
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
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.teal,
            foregroundColor: Colors.white,
          ),
        ),
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
    return Scaffold(
      backgroundColor: Colors.teal,
      body: Center(
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_reset, size: 64, color: Colors.teal),
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
                      backgroundColor: Colors.teal,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: _isLoading
                        ? const CircularProgressIndicator(color: Colors.white)
                        : const Text("XÁC NHẬN ĐỔI MẬT KHẨU"),
                  ),
                ),
                TextButton(
                  onPressed: () => Amplify.Auth.signOut(), // Cho phép hủy để đăng nhập lại user khác
                  child: const Text("Quay lại đăng nhập"),
                )
              ],
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
    return Scaffold(
      backgroundColor: Colors.teal,
      body: Center(
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 64, color: Colors.teal),
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
                      backgroundColor: Colors.teal,
                      foregroundColor: Colors.white,
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
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image == null) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Đang mã hóa và upload...')),
    );

    try {
      final String fileId = '${DateTime.now().millisecondsSinceEpoch}';
      final String fileName = 'img_$fileId.enc';

      // 1. Mã hóa & Upload Full (Sử dụng key từ PIN và lưu trữ trực tiếp bằng Bytes)
      final originalBytes = await image.readAsBytes();
      print("UPLOADING: originalBytes = ${originalBytes.length} bytes");
      final encryptedFullBytes = MyEncryptor.encryptData(originalBytes);
      print("UPLOADING: encryptedFullBytes = ${encryptedFullBytes.length} bytes");
      
      await Amplify.Storage.uploadData(
        data: StorageDataPayload.bytes(encryptedFullBytes),
        path: StoragePath.fromString('full/$_userId/$fileName'),
      ).result;

      // 2. Mã hóa & Upload Thumb (Sử dụng thư viện 'image' thuần Dart)
      final decodedImage = img.decodeImage(originalBytes);
      List<int> compressedBytes;
      if (decodedImage != null) {
        final thumbnail = img.copyResize(decodedImage, width: 200, height: 200);
        compressedBytes = img.encodeJpg(thumbnail, quality: 50);
      } else {
        compressedBytes = originalBytes;
      }
      print("UPLOADING: compressedBytes = ${compressedBytes.length} bytes");
      
      final encryptedThumbBytes = MyEncryptor.encryptData(compressedBytes);
      print("UPLOADING: encryptedThumbBytes = ${encryptedThumbBytes.length} bytes");

      // TEST GIẢI MÃ THỬ TRONG BỘ NHỚ NGAY LẬP TỨC
      try {
        final testDecrypted = MyEncryptor.decryptData(encryptedThumbBytes);
        print("TEST TRONG BỘ NHỚ: Giải mã thành công, độ dài = ${testDecrypted.length} bytes");
        bool isMatch = true;
        if (compressedBytes.length != testDecrypted.length) {
          isMatch = false;
        } else {
          for (int i = 0; i < compressedBytes.length; i++) {
            if (compressedBytes[i] != testDecrypted[i]) {
              isMatch = false;
              break;
            }
          }
        }
        print("TEST TRONG BỘ NHỚ: Kết quả khớp hoàn toàn = $isMatch");
      } catch (testError) {
        print("TEST TRONG BỘ NHỚ: Thất bại với lỗi = $testError");
      }
      
      await Amplify.Storage.uploadData(
        data: StorageDataPayload.bytes(encryptedThumbBytes),
        path: StoragePath.fromString('thumb/$_userId/$fileName'),
      ).result;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã sao lưu an toàn!')),
      );
      _fetchFiles();
    } catch (e) {
      print('Lỗi upload: $e');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Lỗi: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kho Ảnh Bí Mật'),
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
      body: _isLoading
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
                        );
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: EncryptedThumbnail(storagePath: item.path),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _uploadEncryptedImage,
        label: const Text('Thêm ảnh'),
        icon: const Icon(Icons.add_a_photo),
      ),
    );
  }
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
      
      // Chạy thử nghiệm các cấu hình IV khác nhau để debug
      MyEncryptor.testDecrypt(Uint8List.fromList(encryptedBytes), widget.storagePath.split('/').last);

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
        Navigator.pop(context);
        Navigator.pop(context);
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
