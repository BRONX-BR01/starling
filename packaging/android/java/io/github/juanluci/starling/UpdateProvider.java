package io.github.juanluci.starling;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.File;
import java.io.FileNotFoundException;

/**
 * The update the game downloaded (files/updates/, game/update_offer.rs), read by Android's package
 * installer: an app may hand another its private files only through a provider like this one. It
 * serves update APKs and explicitly exported diagnostic ZIPs read-only, only to recipients
 * granted access by the install or share intent.
 */
public final class UpdateProvider extends ContentProvider {
    static final String TYPE = "application/vnd.android.package-archive";

    /** content://<package>.updates/<name> for an APK of files/updates/. */
    static Uri uri(String packageName, String name) {
        return Uri.parse("content://" + packageName + ".updates/" + Uri.encode(name));
    }

    private File file(Uri uri) throws FileNotFoundException {
        String name = uri.getLastPathSegment();
        boolean report = uri.getPathSegments().size() == 2
                && "diagnostics".equals(uri.getPathSegments().get(0));
        if (name == null || !(report
                ? name.matches("starling-diagnostics-[0-9]+\\.zip")
                : uri.getPathSegments().size() == 1 && name.matches("[A-Za-z0-9._-]+\\.apk"))) {
            throw new FileNotFoundException(String.valueOf(uri));
        }
        File file = new File(new File(getContext().getFilesDir(), report ? "performance" : "updates"), name);
        if (!file.isFile()) {
            throw new FileNotFoundException(file.getPath());
        }
        return file;
    }

    @Override
    public boolean onCreate() {
        return true;
    }

    @Override
    public String getType(Uri uri) {
        return uri.getPathSegments().size() == 2
                && "diagnostics".equals(uri.getPathSegments().get(0)) ? "application/zip" : TYPE;
    }

    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!"r".equals(mode)) throw new FileNotFoundException("Read-only provider");
        return ParcelFileDescriptor.open(file(uri), ParcelFileDescriptor.MODE_READ_ONLY);
    }

    /** The name and size, which installers ask before reading. */
    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs,
            String sortOrder) {
        File file;
        try {
            file = file(uri);
        } catch (FileNotFoundException e) {
            return null;
        }
        MatrixCursor cursor = new MatrixCursor(
                new String[] {OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE});
        cursor.addRow(new Object[] {file.getName(), file.length()});
        return cursor;
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        throw new UnsupportedOperationException();
    }

    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) {
        throw new UnsupportedOperationException();
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) {
        throw new UnsupportedOperationException();
    }
}
