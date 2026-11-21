package android.net

import android.os.Parcel

internal class TestUri private constructor(
    private val uriScheme: String = "content",
    private val uriAuthority: String = "test",
    private val uriPath: String = "/photo",
) : Uri() {
    override fun isHierarchical() = true
    override fun isRelative() = false
    override fun getScheme(): String = uriScheme
    override fun getSchemeSpecificPart(): String = "//$uriAuthority$uriPath"
    override fun getEncodedSchemeSpecificPart(): String = "//$uriAuthority$uriPath"
    override fun getAuthority(): String = uriAuthority
    override fun getEncodedAuthority(): String = uriAuthority
    override fun getUserInfo(): String? = null
    override fun getEncodedUserInfo(): String? = null
    override fun getHost(): String = uriAuthority
    override fun getPort() = -1
    override fun getPath(): String = uriPath
    override fun getEncodedPath(): String = uriPath
    override fun getQuery(): String? = null
    override fun getEncodedQuery(): String? = null
    override fun getFragment(): String? = null
    override fun getEncodedFragment(): String? = null
    override fun getPathSegments(): List<String> = uriPath.trim('/').split('/').filter(String::isNotEmpty)
    override fun getLastPathSegment(): String? = pathSegments.lastOrNull()
    override fun toString() = "$uriScheme://$uriAuthority$uriPath"
    override fun buildUpon(): Builder = throw UnsupportedOperationException()
    override fun describeContents() = 0
    override fun writeToParcel(destination: Parcel, flags: Int) = Unit
    override fun equals(other: Any?): Boolean = other is Uri && other.toString() == toString()
    override fun hashCode(): Int = toString().hashCode()

    companion object {
        val value: Uri = TestUri()
        fun of(path: String, scheme: String = "content", authority: String = "test"): Uri =
            TestUri(scheme, authority, if (path.startsWith('/')) path else "/$path")
    }
}
