package com.sshtab.ssh_pad_flutter

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.documentfile.provider.DocumentFile
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

/**
 * Scoped-storage local files.
 *
 * Public Download is visible to dart:io only as directories (and files this
 * app created). MediaStore.Downloads (API 29+) supplies the missing files.
 * Other folders use SAF [Intent.ACTION_OPEN_DOCUMENT_TREE] + DocumentFile.
 * Bytes are always read through ContentResolver, never via a raw public path.
 */
class LocalFilesBridge(
    private val activity: MainActivity,
) {
    private var pendingTreeResult: MethodChannel.Result? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "listDownloadFiles" -> {
                val directory = call.argument<String>("directory") ?: ""
                bg(result) { listDownloadFiles(directory) }
            }
            "openDocumentTree" -> openDocumentTree(result)
            "listSafChildren" -> {
                val treeUri = call.argument<String>("treeUri") ?: ""
                val documentUri = call.argument<String>("documentUri")
                bg(result) { listSafChildren(treeUri, documentUri) }
            }
            "readContentUri" -> {
                val uri = call.argument<String>("uri") ?: ""
                bg(result) { readContentUri(uri) }
            }
            "writeSafFile" -> {
                val treeUri = call.argument<String>("treeUri") ?: ""
                val parentDocumentUri = call.argument<String>("parentDocumentUri")
                val name = call.argument<String>("name") ?: ""
                val sourcePath = call.argument<String>("sourcePath") ?: ""
                bg(result) { writeSafFile(treeUri, parentDocumentUri, name, sourcePath) }
            }
            else -> result.notImplemented()
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQ_OPEN_TREE) return false
        val pending = pendingTreeResult
        pendingTreeResult = null
        if (pending == null) return true
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            pending.success(null)
            return true
        }
        val uri = data.data!!
        val takeFlags = data.flags and (
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        try {
            activity.contentResolver.takePersistableUriPermission(uri, takeFlags)
        } catch (e: Exception) {
            Log.w(TAG, "takePersistableUriPermission failed: $e")
            try {
                activity.contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            } catch (e2: Exception) {
                Log.w(TAG, "read-only persist also failed: $e2")
            }
        }
        val prefs = activity.getSharedPreferences(PREFS, Activity.MODE_PRIVATE)
        val set = prefs.getStringSet(PREF_TREES, emptySet())!!.toMutableSet()
        set.add(uri.toString())
        prefs.edit().putStringSet(PREF_TREES, set).apply()
        val doc = DocumentFile.fromTreeUri(activity, uri)
        val name = doc?.name ?: "folder"
        pending.success(
            mapOf(
                "treeUri" to uri.toString(),
                "name" to name,
                "displayPath" to name,
            ),
        )
        return true
    }

    private fun openDocumentTree(result: MethodChannel.Result) {
        if (pendingTreeResult != null) {
            result.error("busy", "folder picker already open", null)
            return
        }
        pendingTreeResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                putExtra(
                    DocumentsContract.EXTRA_INITIAL_URI,
                    Uri.parse(
                        "content://com.android.externalstorage.documents/document/primary:Download",
                    ),
                )
            }
        }
        try {
            activity.startActivityForResult(intent, REQ_OPEN_TREE)
        } catch (e: Exception) {
            pendingTreeResult = null
            result.error("picker", e.message, null)
        }
    }

    private fun listDownloadFiles(directory: String): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < 29) return emptyList()
        val norm = directory.trimEnd('/')
        val rels = relativeCandidates(norm)
        if (rels.isEmpty()) return emptyList()
        val out = LinkedHashMap<String, MutableMap<String, Any?>>()
        val collections = listOf(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            MediaStore.Files.getContentUri("external"),
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
        )
        for (collection in collections) {
            queryCollection(collection, norm, rels, out)
        }
        return out.values.map { it.toMap() }
    }

    private fun queryCollection(
        collection: Uri,
        directory: String,
        rels: List<String>,
        out: LinkedHashMap<String, MutableMap<String, Any?>>,
    ) {
        val args = ArrayList<String>()
        val clauses = ArrayList<String>()
        val relCol = MediaStore.MediaColumns.RELATIVE_PATH
        for (r in rels) {
            clauses.add("$relCol = ?")
            args.add(r)
            val bare = r.removeSuffix("/")
            if (bare != r) {
                clauses.add("$relCol = ?")
                args.add(bare)
            }
        }
        clauses.add("${MediaStore.MediaColumns.DATA} LIKE ?")
        args.add("$directory/%")
        val selection = "(${clauses.joinToString(" OR ")})"
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.RELATIVE_PATH,
            MediaStore.MediaColumns.DATA,
            MediaStore.MediaColumns.MIME_TYPE,
        )
        val relOnlySelection = rels.flatMap { r ->
            val bare = r.removeSuffix("/")
            if (bare == r) listOf(r) else listOf(r, bare)
        }
        val relArgs = relOnlySelection.toTypedArray()
        val relSelection = relOnlySelection.joinToString(" OR ") { "$relCol = ?" }
        try {
            val cursor = try {
                activity.contentResolver.query(
                    collection,
                    projection,
                    selection,
                    args.toTypedArray(),
                    null,
                )
            } catch (e: Exception) {
                Log.w(TAG, "MediaStore DATA query failed, retry relative-only: $e")
                activity.contentResolver.query(
                    collection,
                    arrayOf(
                        MediaStore.MediaColumns._ID,
                        MediaStore.MediaColumns.DISPLAY_NAME,
                        MediaStore.MediaColumns.SIZE,
                        MediaStore.MediaColumns.RELATIVE_PATH,
                    ),
                    relSelection,
                    relArgs,
                    null,
                )
            }
            cursor?.use { cursor ->
                val idIdx = cursor.getColumnIndex(MediaStore.MediaColumns._ID)
                val nameIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
                val sizeIdx = cursor.getColumnIndex(MediaStore.MediaColumns.SIZE)
                val relIdx = cursor.getColumnIndex(MediaStore.MediaColumns.RELATIVE_PATH)
                val dataIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
                while (cursor.moveToNext()) {
                    val name = if (nameIdx >= 0) cursor.getString(nameIdx) else null
                    if (name.isNullOrEmpty() || name.startsWith(".")) continue
                    val rel = if (relIdx >= 0) cursor.getString(relIdx) else null
                    val data = if (dataIdx >= 0) cursor.getString(dataIdx) else null
                    if (!belongsToDir(rel, data, directory, rels)) continue
                    val id = if (idIdx >= 0) cursor.getLong(idIdx) else continue
                    val size = if (sizeIdx >= 0 && !cursor.isNull(sizeIdx)) cursor.getLong(sizeIdx) else null
                    val contentUri = Uri.withAppendedPath(collection, id.toString()).toString()
                    val existing = out[name]
                    if (existing == null) {
                        out[name] = linkedMapOf(
                            "name" to name,
                            "path" to (data ?: "$directory/$name"),
                            "isDirectory" to false,
                            "size" to size,
                            "contentUri" to contentUri,
                        )
                    } else if (existing["contentUri"] == null) {
                        existing["contentUri"] = contentUri
                        if (existing["size"] == null && size != null) existing["size"] = size
                    }
                }
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "MediaStore query denied $collection: $e")
        } catch (e: Exception) {
            Log.w(TAG, "MediaStore query failed $collection: $e")
        }
    }

    private fun listSafChildren(treeUri: String, documentUri: String?): List<Map<String, Any?>> {
        if (treeUri.isEmpty()) return emptyList()
        val tree = Uri.parse(treeUri)
        val folder = if (documentUri.isNullOrEmpty()) {
            DocumentFile.fromTreeUri(activity, tree)
        } else {
            DocumentFile.fromSingleUri(activity, Uri.parse(documentUri))
        } ?: return emptyList()
        if (!folder.isDirectory) return emptyList()
        val children = try {
            folder.listFiles()
        } catch (e: Exception) {
            Log.w(TAG, "SAF listFiles failed: $e")
            emptyArray()
        }
        val out = ArrayList<Map<String, Any?>>(children.size)
        for (child in children) {
            val name = child.name ?: continue
            if (name.startsWith(".")) continue
            val isDir = child.isDirectory
            out.add(
                mapOf(
                    "name" to name,
                    "path" to child.uri.toString(),
                    "isDirectory" to isDir,
                    "size" to if (!isDir) child.length() else null,
                    "contentUri" to if (!isDir) child.uri.toString() else null,
                    "documentUri" to child.uri.toString(),
                ),
            )
        }
        return out
    }

    /** Copy a content Uri into app cache. Returns the cache file path. */
    private fun readContentUri(uriString: String): String {
        if (uriString.isEmpty()) throw IllegalArgumentException("empty uri")
        sweepCache()
        val uri = Uri.parse(uriString)
        val display = queryDisplayName(uri) ?: (uri.lastPathSegment ?: "file")
        val safe = display.replace(Regex("[^A-Za-z0-9._-]"), "_").take(80)
        val out = File(activity.cacheDir, "sshpad_uri_${System.currentTimeMillis()}_$safe")
        activity.contentResolver.openInputStream(uri)?.use { input ->
            out.outputStream().use { output -> input.copyTo(output) }
        } ?: throw IllegalStateException("cannot open $uriString")
        return out.absolutePath
    }

    private fun writeSafFile(
        treeUri: String,
        parentDocumentUri: String?,
        name: String,
        sourcePath: String,
    ): String {
        if (name.isEmpty() || sourcePath.isEmpty() || treeUri.isEmpty()) {
            throw IllegalArgumentException("missing write args")
        }
        val tree = Uri.parse(treeUri)
        val parent = if (parentDocumentUri.isNullOrEmpty()) {
            DocumentFile.fromTreeUri(activity, tree)
        } else {
            DocumentFile.fromSingleUri(activity, Uri.parse(parentDocumentUri))
        } ?: throw IllegalStateException("SAF folder missing")
        val src = File(sourcePath)
        if (!src.isFile) throw IllegalStateException("source missing")
        parent.findFile(name)?.delete()
        val ext = name.substringAfterLast('.', "").lowercase(Locale.US)
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: "application/octet-stream"
        val created = parent.createFile(mime, name)
            ?: throw IllegalStateException("createFile failed")
        activity.contentResolver.openOutputStream(created.uri)?.use { output ->
            src.inputStream().use { input -> input.copyTo(output) }
        } ?: throw IllegalStateException("cannot write ${created.uri}")
        return created.uri.toString()
    }

    private fun queryDisplayName(uri: Uri): String? {
        return try {
            activity.contentResolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)
                ?.use { c ->
                    if (c.moveToFirst()) c.getString(0) else null
                }
        } catch (_: Exception) {
            null
        }
    }

    private fun sweepCache() {
        val dir = activity.cacheDir ?: return
        val cutoff = System.currentTimeMillis() - 60 * 60 * 1000
        dir.listFiles()?.forEach { f ->
            if (f.name.startsWith("sshpad_uri_") && f.lastModified() < cutoff) {
                f.delete()
            }
        }
    }

    private fun bg(result: MethodChannel.Result, block: () -> Any?) {
        Thread {
            try {
                val value = block()
                activity.runOnUiThread { result.success(value) }
            } catch (e: Exception) {
                Log.w(TAG, "storage call failed: $e")
                activity.runOnUiThread {
                    result.error("storage", e.message ?: e.toString(), null)
                }
            }
        }.start()
    }

    companion object {
        private const val TAG = "SshPadFiles"
        const val REQ_OPEN_TREE = 4403
        private const val PREFS = "sshpad_saf"
        private const val PREF_TREES = "trees"

        /** `Download/` or `Download/Sub/Dir/` candidates for a public downloads path. */
        fun relativeCandidates(directory: String): List<String> {
            val norm = directory.trimEnd('/')
            val m = Regex("""^/storage/emulated/\d+/(Download|Downloads)(?:/(.*))?$""")
                .matchEntire(norm) ?: return emptyList()
            val root = m.groupValues[1]
            val rest = m.groupValues[2].trim('/')
            val roots = linkedSetOf(root)
            if (root.equals("Download", ignoreCase = true)) roots.add("Downloads")
            if (root.equals("Downloads", ignoreCase = true)) roots.add("Download")
            val out = ArrayList<String>()
            for (r in roots) {
                val rel = if (rest.isEmpty()) "$r/" else "$r/$rest/"
                out.add(rel)
            }
            return out
        }

        fun belongsToDir(
            relativePath: String?,
            dataPath: String?,
            directory: String,
            rels: List<String>,
        ): Boolean {
            if (!relativePath.isNullOrEmpty()) {
                val withSlash = if (relativePath.endsWith("/")) relativePath else "$relativePath/"
                if (rels.any { it == relativePath || it == withSlash }) return true
            }
            if (!dataPath.isNullOrEmpty()) {
                val parent = File(dataPath).parent?.trimEnd('/')
                if (parent == directory.trimEnd('/')) return true
            }
            return false
        }
    }
}
