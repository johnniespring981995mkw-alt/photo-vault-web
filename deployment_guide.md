# Hướng Dẫn Deploy PhotoCloud Lên GitHub Pages

Tài liệu này hướng dẫn bạn cách tải mã nguồn lên GitHub (không cần cài Git trên máy) và cấu hình AWS S3 CORS để chạy ứng dụng trên Web hoàn toàn miễn phí.

---

## BƯỚC 1: Đưa Dự Án Lên GitHub (Giao diện web, không dùng dòng lệnh)

Hệ thống đã chuẩn bị sẵn tệp `.github/workflows/deploy.yml` để GitHub tự động biên dịch và triển khai ứng dụng của bạn lên GitHub Pages. Bạn chỉ cần tải tệp lên qua trang web:

1. **Tạo Repository mới trên GitHub:** 
   * Truy cập [github.com](https://github.com) và tạo một Repository mới (ví dụ đặt tên là `photo-vault` hoặc `photoCloud`). 
   * Chọn chế độ **Public** (để dùng tính năng GitHub Pages miễn phí).
   * **Không** tích chọn bất kỳ mục nào như *Add a README file*, *Add .gitignore* hay *Choose a license*.
2. **Kéo thả để tải file:**
   * Sau khi tạo xong Repo, tại giao diện trống hiện ra, nhấn vào liên kết **"uploading an existing file"** ở dòng giới thiệu đầu tiên.
   * Thực hiện kéo và thả toàn bộ các thư mục và tệp sau đây trong thư mục `photoCloud` vào trình duyệt:
     * `pubspec.yaml`
     * Thư mục `lib/` (Bên trong có `main.dart`, `download_helper.dart`, `download_helper_stub.dart`, `download_helper_web.dart`, `download_helper_mobile.dart`).
     * **LƯU Ý QUAN TRỌNG:** Bạn cần sao chép tệp cấu hình AWS Amplify `amplify_outputs.dart` của bạn vào trong thư mục `lib/` trước khi tải lên (ở vị trí cùng cấp với `main.dart`).
     * Thư mục `web/` (Bên trong chứa `index.html`).
     * Thư mục `.github/` (Bên trong chứa thư mục `workflows/` và tệp `deploy.yml`).
3. **Commit tệp:** Cuộn xuống dưới cùng và nhấn nút **"Commit changes"**.
4. **Kiểm tra tiến trình Deployment:**
   * Chuyển qua tab **Actions** trên Repository của bạn. Bạn sẽ thấy một workflow có tên là *Deploy to GitHub Pages* đang chạy tự động để build ứng dụng Flutter Web.
   * Khi tiến trình hoàn thành (chuyển sang màu xanh lá), truy cập vào mục **Settings** -> **Pages** ở thanh công cụ bên trái của Repository.
   * Tại phần **Build and deployment**, đảm bảo nguồn chọn là **Deploy from a branch**, và nhánh đích được chọn là **`gh-pages`** (thường hệ thống sẽ tự động thiết lập).
   * Bạn sẽ nhận được đường dẫn trang web dạng: `https://<tên-tài-khoản>.github.io/<tên-repository>/`.

---

## BƯỚC 2: Cấu hình AWS S3 CORS (Bắt buộc)

Do ứng dụng chạy trực tuyến trên trình duyệt web, AWS S3 mặc định sẽ chặn các truy cập lấy hoặc gửi ảnh từ các tên miền khác không phải AWS (lỗi CORS). Hãy cấu hình lại S3 Bucket của bạn:

1. Đăng nhập vào [AWS Console](https://aws.amazon.com).
2. Tìm kiếm dịch vụ **S3** và chọn mục **Buckets**.
3. Click vào Bucket đang chứa dữ liệu ảnh của ứng dụng (thường có tên dạng `amplify-...-storage-...`).
4. Chuyển qua tab **Permissions** (Quyền truy cập).
5. Cuộn xuống dưới cùng tìm mục **Cross-origin resource sharing (CORS)** và chọn **Edit**.
6. Dán cấu hình JSON sau đây vào ô cấu hình:
   ```json
   [
       {
           "AllowedHeaders": [
               "*"
           ],
           "AllowedMethods": [
               "GET",
               "HEAD",
               "PUT",
               "POST",
               "DELETE"
           ],
           "AllowedOrigins": [
               "https://*.github.io",
               "http://localhost:*"
           ],
           "ExposeHeaders": [
               "x-amz-server-side-encryption",
               "x-amz-request-id",
               "x-amz-id-2",
               "ETag"
           ],
           "MaxAgeSeconds": 3000
       }
   ]
   ```
   *(Cấu hình này cho phép các ứng dụng chạy trên GitHub Pages của bạn và máy chạy thử nghiệm nội bộ Localhost được phép gọi các API tải/đọc hình ảnh từ S3).*
7. Nhấn **Save changes** để hoàn tất.

Giờ đây bạn đã có thể truy cập vào đường dẫn GitHub Pages của mình, đăng nhập tài khoản AWS và bắt đầu sử dụng Kho Ảnh Bí Mật trực tiếp trên Web hoàn toàn miễn phí!
