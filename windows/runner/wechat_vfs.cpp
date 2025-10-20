#include <windows.h>
#include <string>
#include <map>
#include <cstring>
#include <vector>

// Minimal AES decryption using Windows CNG (no external dependencies)
#include <bcrypt.h>
#pragma comment(lib, "bcrypt.lib")

// SQLite3 types and constants (minimal definitions)
typedef long long sqlite3_int64;

#define SQLITE_OK           0
#define SQLITE_ERROR        1
#define SQLITE_READONLY     8

// Forward declarations
struct sqlite3_file {
    const struct sqlite3_io_methods *pMethods;
};

struct sqlite3_io_methods {
    int iVersion;
    int (*xClose)(sqlite3_file*);
    int (*xRead)(sqlite3_file*, void*, int iAmt, sqlite3_int64 iOfst);
    int (*xWrite)(sqlite3_file*, const void*, int iAmt, sqlite3_int64 iOfst);
    int (*xTruncate)(sqlite3_file*, sqlite3_int64 size);
    int (*xSync)(sqlite3_file*, int flags);
    int (*xFileSize)(sqlite3_file*, sqlite3_int64 *pSize);
    int (*xLock)(sqlite3_file*, int);
    int (*xUnlock)(sqlite3_file*, int);
    int (*xCheckReservedLock)(sqlite3_file*, int *pResOut);
    int (*xFileControl)(sqlite3_file*, int op, void *pArg);
    int (*xSectorSize)(sqlite3_file*);
    int (*xDeviceCharacteristics)(sqlite3_file*);
};

struct sqlite3_vfs {
    int iVersion;
    int szOsFile;
    int mxPathname;
    sqlite3_vfs *pNext;
    const char *zName;
    void *pAppData;
    int (*xOpen)(sqlite3_vfs*, const char *zName, sqlite3_file*, int flags, int *pOutFlags);
    int (*xDelete)(sqlite3_vfs*, const char *zName, int syncDir);
    int (*xAccess)(sqlite3_vfs*, const char *zName, int flags, int *pResOut);
    int (*xFullPathname)(sqlite3_vfs*, const char *zName, int nOut, char *zOut);
    void *(*xDlOpen)(sqlite3_vfs*, const char *zFilename);
    void (*xDlError)(sqlite3_vfs*, int nByte, char *zErrMsg);
    void (*(*xDlSym)(sqlite3_vfs*, void*, const char *zSymbol))(void);
    void (*xDlClose)(sqlite3_vfs*, void*);
    int (*xRandomness)(sqlite3_vfs*, int nByte, char *zOut);
    int (*xSleep)(sqlite3_vfs*, int microseconds);
    int (*xCurrentTime)(sqlite3_vfs*, double*);
    int (*xGetLastError)(sqlite3_vfs*, int, char *);
};

// Function pointer types
typedef sqlite3_vfs* (*sqlite3_vfs_find_t)(const char*);
typedef int (*sqlite3_vfs_register_t)(sqlite3_vfs*, int);
typedef int (*sqlite3_vfs_unregister_t)(sqlite3_vfs*);

static sqlite3_vfs_find_t p_sqlite3_vfs_find = nullptr;
static sqlite3_vfs_register_t p_sqlite3_vfs_register = nullptr;
static sqlite3_vfs_unregister_t p_sqlite3_vfs_unregister = nullptr;
static HMODULE sqlite3_module = nullptr;

// Lightweight VFS implementation - only intercepts reads, decryption done by Dart

#define PAGE_SIZE 4096
#define SALT_SIZE 16
#define IV_SIZE 16
#define RESERVE_SIZE 80

// Structure to store encryption keys for each database
struct EncryptionKeys {
    std::vector<unsigned char> encKey;
    std::vector<unsigned char> macKey;
};

// Simple AES-256-CBC decryption using Windows CNG
static bool aes_decrypt_cbc(const unsigned char* encrypted, int encrypted_len,
                           const unsigned char* key, const unsigned char* iv,
                           unsigned char* decrypted) {
    BCRYPT_ALG_HANDLE hAlg = NULL;
    BCRYPT_KEY_HANDLE hKey = NULL;
    NTSTATUS status;
    
    // Open algorithm provider
    status = BCryptOpenAlgorithmProvider(&hAlg, BCRYPT_AES_ALGORITHM, NULL, 0);
    if (!BCRYPT_SUCCESS(status)) return false;
    
    // Set chaining mode to CBC
    status = BCryptSetProperty(hAlg, BCRYPT_CHAINING_MODE,
                              (PBYTE)BCRYPT_CHAIN_MODE_CBC,
                              sizeof(BCRYPT_CHAIN_MODE_CBC), 0);
    if (!BCRYPT_SUCCESS(status)) {
        BCryptCloseAlgorithmProvider(hAlg, 0);
        return false;
    }
    
    // Generate key object
    status = BCryptGenerateSymmetricKey(hAlg, &hKey, NULL, 0,
                                       (PBYTE)key, 32, 0);  // 256 bits = 32 bytes
    if (!BCRYPT_SUCCESS(status)) {
        BCryptCloseAlgorithmProvider(hAlg, 0);
        return false;
    }
    
    // Decrypt
    ULONG result_len = 0;
    status = BCryptDecrypt(hKey, (PBYTE)encrypted, encrypted_len,
                          NULL, (PBYTE)iv, IV_SIZE,
                          decrypted, encrypted_len, &result_len, 0);
    
    BCryptDestroyKey(hKey);
    BCryptCloseAlgorithmProvider(hAlg, 0);
    
    return BCRYPT_SUCCESS(status);
}

// Helper function to normalize path (convert all backslashes to forward slashes and lowercase)
static std::string normalize_path(const std::string& path) {
    std::string normalized = path;
    for (char& c : normalized) {
        if (c == '\\') c = '/';
        if (c >= 'A' && c <= 'Z') c = c - 'A' + 'a';
    }
    return normalized;
}

// Global keys mapping (path -> keys)
static std::map<std::string, EncryptionKeys> g_encryption_keys;
static sqlite3_vfs* g_default_vfs = nullptr;

// Custom file handle
struct WeChatFile {
    sqlite3_file base;
    sqlite3_file* real_file;
    std::string path;
    EncryptionKeys* keys;  // Pointer to keys, NULL if no encryption
};

// Thread-local storage for page buffers to avoid allocation/deallocation on every read
// This keeps buffers alive during async callback execution
thread_local static unsigned char* g_encrypted_buffer = nullptr;
thread_local static unsigned char* g_decrypted_buffer = nullptr;

static void ensure_buffers_allocated() {
    if (!g_encrypted_buffer) {
        g_encrypted_buffer = new unsigned char[PAGE_SIZE];
    }
    if (!g_decrypted_buffer) {
        g_decrypted_buffer = new unsigned char[PAGE_SIZE];
    }
}

// VFS method implementations
static int wechat_close(sqlite3_file* pFile) {
    WeChatFile* p = (WeChatFile*)pFile;
    int rc = p->real_file->pMethods->xClose(p->real_file);
    delete p->real_file;
    return rc;
}

static int wechat_read(sqlite3_file* pFile, void* zBuf, int iAmt, sqlite3_int64 iOfst) {
    WeChatFile* p = (WeChatFile*)pFile;
    
    // Debug: Log read operation
    if (iOfst == 0 && iAmt <= 100) {
        fprintf(stderr, "[VFS C++] xRead called: offset=%lld, size=%d, has_callback=%s\n", 
                iOfst, iAmt, p->decrypt_cb ? "YES" : "NO");
        fflush(stderr);
    }
    
    // If no decrypt callback, pass through to default VFS
    if (!p->decrypt_cb) {
        return p->real_file->pMethods->xRead(p->real_file, zBuf, iAmt, iOfst);
    }
    
    // Calculate page boundaries
    int start_page = (int)(iOfst / PAGE_SIZE);
    int end_page = (int)((iOfst + iAmt - 1) / PAGE_SIZE);
    int start_offset = (int)(iOfst % PAGE_SIZE);
    
    unsigned char* output = (unsigned char*)zBuf;
    int bytes_written = 0;
    
    // Ensure thread-local buffers are allocated
    ensure_buffers_allocated();
    
    // Read and decrypt each page
    for (int page_num = start_page; page_num <= end_page; page_num++) {
        sqlite3_int64 page_offset = (sqlite3_int64)page_num * PAGE_SIZE;
        
        fprintf(stderr, "[VFS C++] Reading page %d at offset %lld\n", page_num, page_offset);
        fflush(stderr);
        
        // Read into thread-local buffer (stays alive for async callback)
        int rc = p->real_file->pMethods->xRead(p->real_file, g_encrypted_buffer, PAGE_SIZE, page_offset);
        fprintf(stderr, "[VFS C++] xRead returned: %d (SQLITE_OK=%d)\n", rc, SQLITE_OK);
        fflush(stderr);
        
        if (rc != SQLITE_OK) {
            fprintf(stderr, "[VFS C++] xRead failed with rc=%d\n", rc);
            fflush(stderr);
            return rc;
        }
        
        // Debug: Print first 16 bytes of encrypted page 0
        if (page_num == 0) {
            fprintf(stderr, "[VFS C++] Page 0 encrypted (first 16 bytes): ");
            for (int i = 0; i < 16; i++) {
                fprintf(stderr, "%02x ", g_encrypted_buffer[i]);
            }
            fprintf(stderr, "\n");
            fflush(stderr);
        }
        
        // Decrypt the page using C++ (Windows CNG)
        if (!p->keys) {
            // No encryption, copy as-is
            memcpy(g_decrypted_buffer, g_encrypted_buffer, PAGE_SIZE);
        } else {
            // Decrypt with AES-256-CBC
            int offset = (page_num == 0) ? SALT_SIZE : 0;
            
            // Extract IV from reserve area
            const unsigned char* iv = g_encrypted_buffer + PAGE_SIZE - RESERVE_SIZE;
            
            // Decrypt the encrypted portion
            int encrypted_len = PAGE_SIZE - RESERVE_SIZE - offset;
            if (!aes_decrypt_cbc(g_encrypted_buffer + offset, encrypted_len,
                                p->keys->encKey.data(), iv,
                                g_decrypted_buffer)) {
                fprintf(stderr, "[VFS C++] AES decryption failed for page %d\n", page_num);
                fflush(stderr);
                return SQLITE_ERROR;
            }
            
            // Copy reserve area
            memcpy(g_decrypted_buffer + encrypted_len, 
                   g_encrypted_buffer + PAGE_SIZE - RESERVE_SIZE, 
                   RESERVE_SIZE);
            
            // For page 0, pad the end with zeros
            if (page_num == 0) {
                memset(g_decrypted_buffer + encrypted_len + RESERVE_SIZE, 0, SALT_SIZE);
            }
        }
        
        // Debug: Print first 16 bytes of decrypted page 0
        if (page_num == 0) {
            fprintf(stderr, "[VFS C++] Page 0 decrypted (first 16 bytes): ");
            for (int i = 0; i < 16; i++) {
                fprintf(stderr, "%02x ", g_decrypted_buffer[i]);
            }
            fprintf(stderr, "\n");
            fflush(stderr);
        }
        
        // Calculate how much to copy from this page
        int copy_offset = (page_num == start_page) ? start_offset : 0;
        int bytes_in_page = PAGE_SIZE - copy_offset;
        int bytes_remaining = iAmt - bytes_written;
        int bytes_to_copy = (bytes_in_page < bytes_remaining) ? bytes_in_page : bytes_remaining;
        
        // Copy the decrypted data
        memcpy(output + bytes_written, g_decrypted_buffer + copy_offset, bytes_to_copy);
        bytes_written += bytes_to_copy;
    }
    
    return SQLITE_OK;
}

static int wechat_write(sqlite3_file* pFile, const void* zBuf, int iAmt, sqlite3_int64 iOfst) {
    return SQLITE_READONLY;
}

static int wechat_truncate(sqlite3_file* pFile, sqlite3_int64 size) {
    return SQLITE_READONLY;
}

static int wechat_sync(sqlite3_file* pFile, int flags) {
    WeChatFile* p = (WeChatFile*)pFile;
    return p->real_file->pMethods->xSync(p->real_file, flags);
}

static int wechat_file_size(sqlite3_file* pFile, sqlite3_int64* pSize) {
    WeChatFile* p = (WeChatFile*)pFile;
    return p->real_file->pMethods->xFileSize(p->real_file, pSize);
}

static int wechat_lock(sqlite3_file* pFile, int eLock) {
    WeChatFile* p = (WeChatFile*)pFile;
    return p->real_file->pMethods->xLock(p->real_file, eLock);
}

static int wechat_unlock(sqlite3_file* pFile, int eLock) {
    WeChatFile* p = (WeChatFile*)pFile;
    return p->real_file->pMethods->xUnlock(p->real_file, eLock);
}

static int wechat_check_reserved_lock(sqlite3_file* pFile, int* pResOut) {
    WeChatFile* p = (WeChatFile*)pFile;
    return p->real_file->pMethods->xCheckReservedLock(p->real_file, pResOut);
}

static int wechat_file_control(sqlite3_file* pFile, int op, void* pArg) {
    WeChatFile* p = (WeChatFile*)pFile;
    return p->real_file->pMethods->xFileControl(p->real_file, op, pArg);
}

static int wechat_sector_size(sqlite3_file* pFile) {
    WeChatFile* p = (WeChatFile*)pFile;
    return p->real_file->pMethods->xSectorSize(p->real_file);
}

static int wechat_device_characteristics(sqlite3_file* pFile) {
    WeChatFile* p = (WeChatFile*)pFile;
    return p->real_file->pMethods->xDeviceCharacteristics(p->real_file);
}

static sqlite3_io_methods wechat_io_methods = {
    1,
    wechat_close,
    wechat_read,
    wechat_write,
    wechat_truncate,
    wechat_sync,
    wechat_file_size,
    wechat_lock,
    wechat_unlock,
    wechat_check_reserved_lock,
    wechat_file_control,
    wechat_sector_size,
    wechat_device_characteristics,
};

static int wechat_open(sqlite3_vfs* pVfs, const char* zName, sqlite3_file* pFile, int flags, int* pOutFlags) {
    WeChatFile* p = (WeChatFile*)pFile;
    
    p->real_file = (sqlite3_file*)new char[g_default_vfs->szOsFile];
    
    int rc = g_default_vfs->xOpen(g_default_vfs, zName, p->real_file, flags, pOutFlags);
    if (rc != SQLITE_OK) {
        delete[] (char*)p->real_file;
        return rc;
    }
    
    p->base.pMethods = &wechat_io_methods;
    
    if (zName) {
        p->path = zName;
        std::string normalized = normalize_path(zName);
        auto it = g_encryption_keys.find(normalized);
        p->keys = (it != g_encryption_keys.end()) ? &it->second : nullptr;
        
        // Debug: Use stderr for console output (visible in Flutter)
        fprintf(stderr, "[VFS C++] Opening file: %s\n", zName);
        fflush(stderr);
        fprintf(stderr, "[VFS C++] Normalized path: %s\n", normalized.c_str());
        fflush(stderr);
        fprintf(stderr, "[VFS C++] Keys found: %s\n", p->keys ? "YES" : "NO");
        fflush(stderr);
        fprintf(stderr, "[VFS C++] Registered keys count: %zu\n", g_encryption_keys.size());
        fflush(stderr);
        // Print all registered paths
        for (const auto& pair : g_encryption_keys) {
            fprintf(stderr, "[VFS C++] Registered path: %s\n", pair.first.c_str());
            fflush(stderr);
        }
    } else {
        p->keys = nullptr;
    }
    
    return SQLITE_OK;
}

// Forward to default VFS methods
static int wechat_delete(sqlite3_vfs* pVfs, const char* zName, int syncDir) {
    return g_default_vfs->xDelete(g_default_vfs, zName, syncDir);
}

static int wechat_access(sqlite3_vfs* pVfs, const char* zName, int flags, int* pResOut) {
    return g_default_vfs->xAccess(g_default_vfs, zName, flags, pResOut);
}

static int wechat_full_pathname(sqlite3_vfs* pVfs, const char* zName, int nOut, char* zOut) {
    return g_default_vfs->xFullPathname(g_default_vfs, zName, nOut, zOut);
}

static void* wechat_dlopen(sqlite3_vfs* pVfs, const char* zFilename) {
    return g_default_vfs->xDlOpen(g_default_vfs, zFilename);
}

static void wechat_dlerror(sqlite3_vfs* pVfs, int nByte, char* zErrMsg) {
    g_default_vfs->xDlError(g_default_vfs, nByte, zErrMsg);
}

static void (*wechat_dlsym(sqlite3_vfs* pVfs, void* pHandle, const char* zSymbol))(void) {
    return g_default_vfs->xDlSym(g_default_vfs, pHandle, zSymbol);
}

static void wechat_dlclose(sqlite3_vfs* pVfs, void* pHandle) {
    g_default_vfs->xDlClose(g_default_vfs, pHandle);
}

static int wechat_randomness(sqlite3_vfs* pVfs, int nByte, char* zOut) {
    return g_default_vfs->xRandomness(g_default_vfs, nByte, zOut);
}

static int wechat_sleep(sqlite3_vfs* pVfs, int microseconds) {
    return g_default_vfs->xSleep(g_default_vfs, microseconds);
}

static int wechat_current_time(sqlite3_vfs* pVfs, double* prNow) {
    return g_default_vfs->xCurrentTime(g_default_vfs, prNow);
}

static int wechat_get_last_error(sqlite3_vfs* pVfs, int nBuf, char* zBuf) {
    return g_default_vfs->xGetLastError(g_default_vfs, nBuf, zBuf);
}

static sqlite3_vfs wechat_vfs = {
    1,
    sizeof(WeChatFile),
    512,
    nullptr,
    "wechat",
    nullptr,
    wechat_open,
    wechat_delete,
    wechat_access,
    wechat_full_pathname,
    wechat_dlopen,
    wechat_dlerror,
    wechat_dlsym,
    wechat_dlclose,
    wechat_randomness,
    wechat_sleep,
    wechat_current_time,
    wechat_get_last_error,
};

// Exported functions
extern "C" {

__declspec(dllexport) int wechat_vfs_register() {
    // Load SQLite3 functions dynamically
    if (!sqlite3_module) {
        sqlite3_module = LoadLibraryA("sqlite3.dll");
        if (!sqlite3_module) {
            return SQLITE_ERROR;
        }
        
        p_sqlite3_vfs_find = (sqlite3_vfs_find_t)GetProcAddress(sqlite3_module, "sqlite3_vfs_find");
        p_sqlite3_vfs_register = (sqlite3_vfs_register_t)GetProcAddress(sqlite3_module, "sqlite3_vfs_register");
        p_sqlite3_vfs_unregister = (sqlite3_vfs_unregister_t)GetProcAddress(sqlite3_module, "sqlite3_vfs_unregister");
        
        if (!p_sqlite3_vfs_find || !p_sqlite3_vfs_register || !p_sqlite3_vfs_unregister) {
            return SQLITE_ERROR;
        }
    }
    
    g_default_vfs = p_sqlite3_vfs_find(nullptr);
    if (!g_default_vfs) {
        return SQLITE_ERROR;
    }
    // Register as default VFS (second parameter = 1)
    // This makes SQLite use our VFS automatically
    // Note: We use NativeCallable.isolateLocal for callbacks to handle isolate safety
    fprintf(stderr, "[VFS C++] Registering wechat VFS as default\n");
    fflush(stderr);
    return p_sqlite3_vfs_register(&wechat_vfs, 1);
}

__declspec(dllexport) int wechat_vfs_unregister() {
    if (!p_sqlite3_vfs_unregister) {
        return SQLITE_ERROR;
    }
    return p_sqlite3_vfs_unregister(&wechat_vfs);
}

// Helper to convert hex string to bytes
static std::vector<unsigned char> hex_to_bytes(const char* hex) {
    std::vector<unsigned char> bytes;
    size_t len = strlen(hex);
    for (size_t i = 0; i < len; i += 2) {
        unsigned int byte;
        sscanf_s(hex + i, "%2x", &byte);
        bytes.push_back((unsigned char)byte);
    }
    return bytes;
}

__declspec(dllexport) void wechat_vfs_register_keys(const char* db_path, const char* enc_key_hex, const char* mac_key_hex) {
    std::string normalized = normalize_path(db_path);
    fprintf(stderr, "[VFS C++] Registering keys for path: %s\n", db_path);
    fflush(stderr);
    fprintf(stderr, "[VFS C++] Normalized path: %s\n", normalized.c_str());
    fflush(stderr);
    
    EncryptionKeys keys;
    keys.encKey = hex_to_bytes(enc_key_hex);
    keys.macKey = hex_to_bytes(mac_key_hex);
    
    g_encryption_keys[normalized] = keys;
    fprintf(stderr, "[VFS C++] Total keys registered: %zu\n", g_encryption_keys.size());
    fflush(stderr);
}

__declspec(dllexport) void wechat_vfs_unregister_keys(const char* db_path) {
    std::string normalized = normalize_path(db_path);
    g_encryption_keys.erase(normalized);
    fprintf(stderr, "[VFS C++] Unregistered keys for path: %s\n", normalized.c_str());
    fflush(stderr);
}

// Export a function to check keys count
__declspec(dllexport) int wechat_vfs_get_callback_count() {
    return (int)g_encryption_keys.size();
}

} // extern "C"
