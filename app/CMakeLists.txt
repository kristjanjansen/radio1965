cmake_minimum_required(VERSION 3.16)

project(radio65 VERSION 0.6.6 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CMAKE_AUTORCC ON) #NB! without this resources are not included

find_package(Qt6 REQUIRED COMPONENTS Quick Network Multimedia WebView)

qt_standard_project_setup(REQUIRES 6.5)

if(ANDROID)
    set(QT_ANDROID_MIN_SDK_VERSION 28)

    # Android blocks apps from loading the *system* libcrypto.so/libssl.so
    # (linker namespace isolation, see the "not accessible for the
    # namespace" dlopen error) - Qt::Network's TLS backend (needed for every
    # HTTPS call EventsApiClient makes) needs its own bundled copies, or it
    # fails at runtime with "No functional TLS backend was found". Point
    # this at a checkout of https://github.com/KDAB/android_openssl;
    # defaults to this machine's existing copy under the Android SDK.
    set(RADIO65_ANDROID_OPENSSL_DIR "/home/tarmo/Android/Sdk/android_openssl" CACHE PATH
        "Path to a github.com/KDAB/android_openssl checkout (provides libcrypto/libssl for Android)")
endif()

if(IOS)
    enable_language(OBJCXX)
    enable_language(Swift)
endif()

option(RADIO65_ENABLE_NOTIFICATIONS "Build the in-app notification manager" ON)
option(RADIO65_ENABLE_PUSH "Build native push wiring (Firebase/FCM/APNs)" ON)
# QML-layout-only variant: no broadcast/mic (and the lame cross-compile
# that needs a working NDK/Xcode toolchain just to configure), no push/
# Firebase (and iOS's hard FATAL_ERROR if ios/Firebase isn't vendored) -
# for checking the UI on a simulator/emulator without any of that set up,
# seeded with dummy data (see Main.qml's layoutPreview branch) instead of
# a live server.
option(RADIO65_LAYOUT_PREVIEW "QML-layout-only variant: no broadcast/mic, no push/Firebase, seeded with dummy data" OFF)
if(RADIO65_LAYOUT_PREVIEW)
    set(RADIO65_ENABLE_PUSH OFF)
endif()

if(ANDROID)
    # Icecast broadcasting (project-description.md #8.1/#9). Android has no
    # system pkg-config/libmp3lame, and no built-in MP3 *encoder* at all
    # (MediaCodec only ships MP3 decode) - so libmp3lame is cross-compiled
    # from source for the target ABI via the NDK's standalone clang, using
    # the same LAME encoding calls as desktop (icecastbroadcaster.cpp is
    # unchanged; only linkage differs here). arm64-v8a only for now.
    if(NOT RADIO65_LAYOUT_PREVIEW)
        include(ExternalProject)
        if(NOT CMAKE_ANDROID_NDK)
            message(FATAL_ERROR "CMAKE_ANDROID_NDK is not set - required to cross-compile libmp3lame for Android")
        endif()
        # NDK toolchain prebuilts are published per-host under different
        # directory names (linux-x86_64 / darwin-x86_64 / windows-x86_64) -
        # hardcoding one broke Mac builds, since this NDK only ships
        # darwin-x86_64 here, not linux-x86_64.
        if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
            set(LAME_NDK_HOST_TAG "darwin-x86_64")
        elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Windows")
            set(LAME_NDK_HOST_TAG "windows-x86_64")
        else()
            set(LAME_NDK_HOST_TAG "linux-x86_64")
        endif()
        set(LAME_TOOLCHAIN_BIN "${CMAKE_ANDROID_NDK}/toolchains/llvm/prebuilt/${LAME_NDK_HOST_TAG}/bin")
        set(LAME_ANDROID_API 28) # matches QT_ANDROID_MIN_SDK_VERSION below
        ExternalProject_Add(lame_android
            URL https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
            URL_HASH SHA256=ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
            CONFIGURE_COMMAND <SOURCE_DIR>/configure
                --host=aarch64-linux-android
                --disable-shared --enable-static --disable-frontend
                --libdir=/usr/local/lib
                CC=${LAME_TOOLCHAIN_BIN}/aarch64-linux-android${LAME_ANDROID_API}-clang
                AR=${LAME_TOOLCHAIN_BIN}/llvm-ar
                RANLIB=${LAME_TOOLCHAIN_BIN}/llvm-ranlib
                CFLAGS=-fPIC
            BUILD_COMMAND make -j
            INSTALL_COMMAND make install DESTDIR=<INSTALL_DIR>
            BUILD_IN_SOURCE TRUE
            BUILD_BYPRODUCTS <INSTALL_DIR>/usr/local/lib/libmp3lame.a
        )
        ExternalProject_Get_Property(lame_android install_dir)
        add_library(mp3lame_android STATIC IMPORTED)
        set_target_properties(mp3lame_android PROPERTIES
            IMPORTED_LOCATION "${install_dir}/usr/local/lib/libmp3lame.a")
        add_dependencies(mp3lame_android lame_android)
        file(MAKE_DIRECTORY "${install_dir}/usr/local/include")
        target_include_directories(mp3lame_android INTERFACE "${install_dir}/usr/local/include")
        set(RADIO65_ENABLE_BROADCAST TRUE)
    endif()
elseif(IOS)
    # iOS device only (arm64) - no Simulator support for now, mirroring the
    # Android arm64-v8a-only scope. Cross-compiled the same way as the
    # Android lame_android target above (ExternalProject_Add + autotools
    # configure/make), just against Xcode's iphoneos SDK/clang instead of
    # the NDK toolchain.
    if(NOT RADIO65_LAYOUT_PREVIEW)
        include(ExternalProject)
        execute_process(COMMAND xcrun --sdk iphoneos --show-sdk-path
            OUTPUT_VARIABLE LAME_IOS_SYSROOT OUTPUT_STRIP_TRAILING_WHITESPACE)
        set(LAME_IOS_MIN_VERSION 15.0) # match Qt's iOS deployment target if it's set explicitly elsewhere
        set(LAME_IOS_CFLAGS "-arch arm64 -isysroot ${LAME_IOS_SYSROOT} -mios-version-min=${LAME_IOS_MIN_VERSION} -fPIC")
        ExternalProject_Add(lame_ios
            URL https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
            URL_HASH SHA256=ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
            CONFIGURE_COMMAND <SOURCE_DIR>/configure
                --host=arm-apple-darwin
                --disable-shared --enable-static --disable-frontend
                CC=${CMAKE_C_COMPILER}
                CFLAGS=${LAME_IOS_CFLAGS}
            BUILD_COMMAND make -j
            INSTALL_COMMAND make install DESTDIR=<INSTALL_DIR>
            BUILD_IN_SOURCE TRUE
            BUILD_BYPRODUCTS <INSTALL_DIR>/usr/local/lib/libmp3lame.a
        )
        ExternalProject_Get_Property(lame_ios install_dir)
        add_library(mp3lame_ios STATIC IMPORTED)
        set_target_properties(mp3lame_ios PROPERTIES
            IMPORTED_LOCATION "${install_dir}/usr/local/lib/libmp3lame.a")
        add_dependencies(mp3lame_ios lame_ios)
        file(MAKE_DIRECTORY "${install_dir}/usr/local/include")
        target_include_directories(mp3lame_ios INTERFACE "${install_dir}/usr/local/include")
        set(RADIO65_ENABLE_BROADCAST TRUE)
    endif()
else()
    # Desktop: libmp3lame comes from the system via pkg-config.
    if(NOT RADIO65_LAYOUT_PREVIEW)
        find_package(PkgConfig REQUIRED)
        pkg_check_modules(MP3LAME REQUIRED IMPORTED_TARGET libmp3lame)
        set(RADIO65_ENABLE_BROADCAST TRUE)
    endif()
endif()

# Belt-and-suspenders: forces the flag off even if some future branch
# above sets it before this point is reached (today only the ANDROID/IOS/
# desktop branches set it, all now skipped above when this is on, but
# this is the single source of truth downstream code should trust).
if(RADIO65_LAYOUT_PREVIEW)
    set(RADIO65_ENABLE_BROADCAST FALSE)
endif()

qt_add_executable(appradio65
    main.cpp
    eventsapiclient.h eventsapiclient.cpp
)

target_compile_definitions(appradio65 PRIVATE APP_VERSION="${PROJECT_VERSION}")

if(RADIO65_ENABLE_NOTIFICATIONS)
    target_sources(appradio65 PRIVATE notificationmanager.h notificationmanager.cpp)
    target_compile_definitions(appradio65 PRIVATE RADIO65_ENABLE_NOTIFICATIONS)
endif()

if(RADIO65_ENABLE_BROADCAST)
    target_sources(appradio65 PRIVATE icecastbroadcaster.h icecastbroadcaster.cpp)
    target_compile_definitions(appradio65 PRIVATE RADIO65_ENABLE_BROADCAST)
endif()

if(RADIO65_LAYOUT_PREVIEW)
    target_sources(appradio65 PRIVATE fakeicecastbroadcaster.h fakeicecastbroadcaster.cpp)
endif()

if(RADIO65_ENABLE_PUSH)
    target_compile_definitions(appradio65 PRIVATE RADIO65_ENABLE_PUSH)
endif()

if(RADIO65_LAYOUT_PREVIEW)
    target_compile_definitions(appradio65 PRIVATE RADIO65_LAYOUT_PREVIEW)
endif()

if(ANDROID AND RADIO65_ENABLE_PUSH)
    target_sources(appradio65 PRIVATE androidpush.cpp)
endif()

if(IOS AND RADIO65_ENABLE_PUSH)
    target_sources(appradio65 PRIVATE iospush.mm iosaudiosession.mm "${CMAKE_CURRENT_SOURCE_DIR}/ios/Radio65SwiftSupport.swift")
endif()

# ScreenKeeper - keeps the display from timing out while media is actively
# playing (Android FLAG_KEEP_SCREEN_ON / iOS idleTimerDisabled), see
# screenkeeper.h. Unrelated to RADIO65_ENABLE_PUSH, so not gated behind it.
target_sources(appradio65 PRIVATE screenkeeper.h)
if(ANDROID)
    target_sources(appradio65 PRIVATE androidscreenkeeper.cpp)
elseif(IOS)
    target_sources(appradio65 PRIVATE iosscreenkeeper.mm)
else()
    target_sources(appradio65 PRIVATE screenkeeper_noop.cpp)
endif()


qt_add_qml_module(appradio65
    URI radio65
    VERSION 1.0
    QML_FILES
        Main.qml
        EventListView.qml
        EventDelegate.qml
        Card.qml
        Box.qml
        Shelf.qml
        CollectionPage.qml
        SearchResultsPage.qml
        WebViewPage.qml
        PlaybackController.qml
        PlayerBar.qml
        ChannelCard.qml
        ChannelList.qml
        VideoPage.qml
        BroadcastPage.qml
        DummyEvents.js
        RESOURCES resources.qrc
)

qt_add_resources(appradio65 "conf"
    PREFIX "/"
    FILES qtquickcontrols2.conf
)

# Qt for iOS sets MACOSX_BUNDLE_GUI_IDENTIFIER automatically since Qt 6.1.
# If you are developing for iOS or macOS you should consider setting an
# explicit, fixed bundle identifier manually though.
set_target_properties(appradio65 PROPERTIES
#    MACOSX_BUNDLE_GUI_IDENTIFIER com.example.appradio65
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
    MACOSX_BUNDLE TRUE
    WIN32_EXECUTABLE TRUE
)

target_link_libraries(appradio65
    PRIVATE Qt6::Quick Qt6::Network Qt6::Multimedia Qt6::WebView
)

if(RADIO65_ENABLE_BROADCAST)
    if(ANDROID)
        target_link_libraries(appradio65 PRIVATE mp3lame_android)
    elseif(IOS)
        target_link_libraries(appradio65 PRIVATE mp3lame_ios)
    else()
        target_link_libraries(appradio65 PRIVATE PkgConfig::MP3LAME)
    endif()
endif()

if(ANDROID)
    set_property(TARGET appradio65 PROPERTY QT_ANDROID_PACKAGE_NAME org.eccm.radio65)
    set_property(TARGET appradio65 PROPERTY QT_ANDROID_PACKAGE_SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/android)

    # androiddeployqt overwrites android:versionName/android:versionCode in
    # the packaged manifest with these, regardless of what's hardcoded in
    # android/AndroidManifest.xml - keeps the Play Store version tied to
    # PROJECT_VERSION above instead of drifting out of sync. versionCode
    # must be a plain increasing integer (Play rejects a re-upload unless
    # it's strictly greater than the last one), so it's derived from
    # MAJOR/MINOR/PATCH rather than reusing the dotted version string.
    set_property(TARGET appradio65 PROPERTY QT_ANDROID_VERSION_NAME ${PROJECT_VERSION})
    math(EXPR RADIO65_ANDROID_VERSION_CODE
        "${PROJECT_VERSION_MAJOR} * 1000000 + ${PROJECT_VERSION_MINOR} * 1000 + ${PROJECT_VERSION_PATCH}")
    set_property(TARGET appradio65 PROPERTY QT_ANDROID_VERSION_CODE ${RADIO65_ANDROID_VERSION_CODE})

    if(EXISTS "${RADIO65_ANDROID_OPENSSL_DIR}/android_openssl.cmake")
        include("${RADIO65_ANDROID_OPENSSL_DIR}/android_openssl.cmake")
        add_android_openssl_libraries(appradio65)
    else()
        message(WARNING "RADIO65_ANDROID_OPENSSL_DIR (${RADIO65_ANDROID_OPENSSL_DIR}) not found - "
            "HTTPS requests will fail at runtime with \"No functional TLS backend was found\". "
            "Set -DRADIO65_ANDROID_OPENSSL_DIR=/path/to/android_openssl (see "
            "https://github.com/KDAB/android_openssl).")
    endif()
endif()

if(IOS)
    target_sources(appradio65 PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/ios/Assets.xcassets")
    set_source_files_properties("${CMAKE_CURRENT_SOURCE_DIR}/ios/Assets.xcassets" PROPERTIES
        MACOSX_PACKAGE_LOCATION Resources
    )

    # GoogleService-Info.plist must land at the bundle root (not a subfolder) for
    # [FIRApp configure] to find it via [NSBundle mainBundle]. "Resources" maps to
    # the iOS bundle root (no Contents/Resources nesting like on macOS).
    target_sources(appradio65 PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/ios/GoogleService-Info.plist")
    set_source_files_properties("${CMAKE_CURRENT_SOURCE_DIR}/ios/GoogleService-Info.plist" PROPERTIES
        MACOSX_PACKAGE_LOCATION Resources
    )

    set_target_properties(appradio65 PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/ios/Info.plist
        XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER org.eccm.radio65
        XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME AppIcon
        XCODE_ATTRIBUTE_MARKETING_VERSION ${PROJECT_VERSION}
        XCODE_ATTRIBUTE_CURRENT_PROJECT_VERSION ${PROJECT_VERSION}
        QT_IOS_LAUNCH_SCREEN ${CMAKE_CURRENT_SOURCE_DIR}/ios/LaunchScreen.storyboard
        XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS ${CMAKE_CURRENT_SOURCE_DIR}/ios/radio65.entitlements
        XCODE_ATTRIBUTE_SWIFT_VERSION "5.0"
        XCODE_ATTRIBUTE_ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES "YES"
    )

    # Firebase iOS SDK is vendored manually (no CocoaPods/SPM) - run
    # ios/scripts/fetch_firebase_sdk.sh first to populate ios/Firebase.
    # Skipped entirely under RADIO65_ENABLE_PUSH=OFF (e.g.
    # RADIO65_LAYOUT_PREVIEW) - otherwise this FATAL_ERRORs on every iOS
    # configure until real Firebase SDKs are fetched, even for a build
    # that has no use for push at all.
    if(RADIO65_ENABLE_PUSH)
        file(GLOB RADIO65_FIREBASE_FRAMEWORKS "${CMAKE_CURRENT_SOURCE_DIR}/ios/Firebase/*.xcframework")
        if(NOT RADIO65_FIREBASE_FRAMEWORKS)
            message(FATAL_ERROR "No Firebase XCFrameworks found in ios/Firebase - run ios/scripts/fetch_firebase_sdk.sh first.")
        endif()
        # GoogleUtilities' GULNSData+zlib category (gul_dataByGzippingData:error:)
        # isn't referenced by any ordinary symbol at link time, so the linker
        # drops that .o from the vendored static XCFramework and it crashes at
        # runtime with "unrecognized selector". A blanket -ObjC would fix that,
        # but it also force-loads every Objective-C .o from every static library
        # on the link line - including Qt's iOS frameworks, which Qt's own CMake
        # package config already lists more than once (harmless normally, since
        # the linker just skips symbols it already has) - producing duplicate
        # symbol errors for Qt's own classes. Force-loading just the one object
        # file we need, via an otherwise-unused symbol that lives in it, avoids
        # that collateral damage.
        target_link_libraries(appradio65 PRIVATE
            ${RADIO65_FIREBASE_FRAMEWORKS}
            "-framework SystemConfiguration"
            "-framework Security"
            "-framework CFNetwork"
            "-framework UserNotifications"
            "-Wl,-u,_GULNSDataZlibErrorDomain"
        )
    endif()

    # Not needed yet for the first UI-only build; enable once HLS/RTMP stream
    # playback via QtMultimedia is wired up.
    qt_add_ios_ffmpeg_libraries(appradio65)
endif()

include(GNUInstallDirs)
install(TARGETS appradio65
    BUNDLE DESTINATION .
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)
