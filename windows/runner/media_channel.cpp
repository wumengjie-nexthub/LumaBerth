#include "media_channel.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <wincodec.h>
#include <propsys.h>
#include <propkey.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <algorithm>
#include <filesystem>
#include <string>

using Microsoft::WRL::ComPtr;
using Value = flutter::EncodableValue;

namespace {
std::wstring Path(const flutter::EncodableMap& fields, const char* key) {
  return std::filesystem::u8path(std::get<std::string>(fields.at(Value(key)))).wstring();
}

HRESULT Thumbnail(const std::wstring& path, const std::wstring& output) {
  ComPtr<IWICImagingFactory> factory;
  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> source;
  HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  if (FAILED(hr)) return hr;
  hr = factory->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ,
                                          WICDecodeMetadataCacheOnDemand, &decoder);
  if (FAILED(hr)) return hr;
  hr = decoder->GetFrame(0, &source);
  if (FAILED(hr)) return hr;
  UINT w, h;
  hr = source->GetSize(&w, &h);
  if (FAILED(hr) || w == 0 || h == 0) return E_INVALIDARG;
  const double factor = std::min(1.0, 480.0 / std::max(w, h));
  w = std::max(1u, static_cast<UINT>(w * factor));
  h = std::max(1u, static_cast<UINT>(h * factor));
  ComPtr<IWICBitmapScaler> scaler;
  hr = factory->CreateBitmapScaler(&scaler);
  if (FAILED(hr)) return hr;
  hr = scaler->Initialize(source.Get(), w, h, WICBitmapInterpolationModeFant);
  if (FAILED(hr)) return hr;
  ComPtr<IWICBitmapSource> oriented;
  hr = scaler.As(&oriented);
  if (FAILED(hr)) return hr;
  ComPtr<IWICMetadataQueryReader> metadata;
  PROPVARIANT orientation{};
  if (SUCCEEDED(source->GetMetadataQueryReader(&metadata))) {
    if (FAILED(metadata->GetMetadataByName(L"/app1/ifd/{ushort=274}", &orientation))) {
      metadata->GetMetadataByName(L"/ifd/{ushort=274}", &orientation);
    }
    if (orientation.vt == VT_UI2 && orientation.uiVal >= 2 && orientation.uiVal <= 8) {
      const UINT transforms[] = {0, 0, WICBitmapTransformFlipHorizontal, WICBitmapTransformRotate180,
          WICBitmapTransformFlipVertical, WICBitmapTransformRotate90 | WICBitmapTransformFlipHorizontal,
          WICBitmapTransformRotate90, WICBitmapTransformRotate270 | WICBitmapTransformFlipHorizontal,
          WICBitmapTransformRotate270};
      ComPtr<IWICBitmapFlipRotator> rotator;
      hr = factory->CreateBitmapFlipRotator(&rotator);
      if (SUCCEEDED(hr)) hr = rotator->Initialize(scaler.Get(),
          static_cast<WICBitmapTransformOptions>(transforms[orientation.uiVal]));
      if (SUCCEEDED(hr)) hr = rotator.As(&oriented);
      if (SUCCEEDED(hr)) hr = oriented->GetSize(&w, &h);
    }
    PropVariantClear(&orientation);
    if (FAILED(hr)) return hr;
  }
  ComPtr<IWICStream> stream;
  hr = factory->CreateStream(&stream);
  if (FAILED(hr)) return hr;
  hr = stream->InitializeFromFilename(output.c_str(), GENERIC_WRITE);
  if (FAILED(hr)) return hr;
  ComPtr<IWICBitmapEncoder> encoder;
  hr = factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr, &encoder);
  if (FAILED(hr)) return hr;
  hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
  if (FAILED(hr)) return hr;
  ComPtr<IWICBitmapFrameEncode> frame;
  hr = encoder->CreateNewFrame(&frame, nullptr);
  if (FAILED(hr)) return hr;
  hr = frame->Initialize(nullptr);
  if (FAILED(hr)) return hr;
  hr = frame->SetSize(w, h);
  if (FAILED(hr)) return hr;
  WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
  hr = frame->SetPixelFormat(&format);
  if (FAILED(hr)) return hr;
  ComPtr<IWICFormatConverter> converter;
  hr = factory->CreateFormatConverter(&converter);
  if (FAILED(hr)) return hr;
  hr = converter->Initialize(oriented.Get(), format, WICBitmapDitherTypeNone,
                             nullptr, 0, WICBitmapPaletteTypeCustom);
  if (FAILED(hr)) return hr;
  hr = frame->WriteSource(converter.Get(), nullptr);
  if (FAILED(hr)) return hr;
  hr = frame->Commit();
  if (FAILED(hr)) return hr;
  return encoder->Commit();
}

Value TakenAt(const std::wstring& path) {
  ComPtr<IPropertyStore> properties;
  PROPVARIANT value{};
  Value result;
  if (SUCCEEDED(SHGetPropertyStoreFromParsingName(path.c_str(), nullptr, GPS_DEFAULT,
                                                  IID_PPV_ARGS(&properties))) &&
      SUCCEEDED(properties->GetValue(PKEY_Photo_DateTaken, &value)) &&
      value.vt == VT_FILETIME) {
    ULARGE_INTEGER time;
    time.LowPart = value.filetime.dwLowDateTime;
    time.HighPart = value.filetime.dwHighDateTime;
    result = Value(static_cast<int64_t>(time.QuadPart / 10000) - 11644473600000LL);
  }
  PropVariantClear(&value);
  return result;
}
}  // namespace

void RegisterMediaChannel(flutter::BinaryMessenger* messenger) {
  flutter::MethodChannel<Value> channel(messenger, "photoalbum/media",
                                        &flutter::StandardMethodCodec::GetInstance());
  channel.SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() != "thumbnail") {
      result->NotImplemented();
      return;
    }
    const auto& fields = std::get<flutter::EncodableMap>(*call.arguments());
    const HRESULT hr = Thumbnail(Path(fields, "source"), Path(fields, "thumb"));
    if (FAILED(hr)) {
      result->Error("codec", "Windows could not decode the photo. For HEIC, install HEIF Image Extensions.");
      return;
    }
    result->Success(TakenAt(Path(fields, "metadata")));
  });
}
