package android.net

import android.os.Parcel

internal class TestUri private constructor() : Uri() {
    override fun isHierarchical() = true
    override fun isRelative() = false
    override fun getScheme(): String = "content"
    override fun getSchemeSpecificPart(): String = "//test/photo"
    override fun getEncodedSchemeSpecificPart(): String = "//test/photo"
    override fun getAuthority(): String = "test"
    override fun getEncodedAuthority(): String = "test"
    override fun getUserInfo(): String? = null
    override fun getEncodedUserInfo(): String? = null
    override fun getHost(): String = "test"
    override fun getPort() = -1
    override fun getPath(): String = "/photo"
    override fun getEncodedPath(): String = "/photo"
    override fun getQuery(): String? = null
    override fun getEncodedQuery(): String? = null
    override fun getFragment(): String? = null
    override fun getEncodedFragment(): String? = null
    override fun getPathSegments(): List<String> = listOf("photo")
    override fun getLastPathSegment(): String = "photo"
    override fun toString() = "content://test/photo"
    override fun buildUpon(): Builder = throw UnsupportedOperationException()
    override fun describeContents() = 0
    override fun writeToParcel(destination: Parcel, flags: Int) = Unit

    companion object {
        val value: Uri = TestUri()
    }
}
