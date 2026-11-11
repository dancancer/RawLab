package com.rawlab.android.camera.protocol;

import java.io.*;
import java.net.InetAddress;
import java.text.ParsePosition;
import java.text.SimpleDateFormat;
import java.util.*;
import javax.net.SocketFactory;

/** Sony 旧内容协议的卡内选片会话；按操作码初始化，只执行媒体操作。 */
public final class SonyLegacyImportSession implements CameraMediaSession {
    private final SonyTetherSession transport;
    private final Map<SonyMobileSession.Asset,SonyTetherSession.LegacyObject> objects=new IdentityHashMap<>();
    private boolean identified,opened;

    public SonyLegacyImportSession(SocketFactory factory,InetAddress address,UUID guid,SonyMobileSession.Reporter reporter) throws IOException {
        transport=new SonyTetherSession(factory,address,guid,reporter,SonyTetherSession.Purpose.IMPORT);
    }

    @Override public SonyMobileSession.Device deviceInfo() throws IOException {
        SonyMobileSession.Device device=transport.inspectDevice();
        identified=true;return device;
    }

    @Override public void openSession() throws IOException {
        if(!identified || opened) throw new IOException("Legacy import session identity not ready");
        try {
            transport.connectRemote();
            transport.enterLegacyContents();opened=true;
        } catch(IOException failure) { close();throw failure; }
    }

    @Override public List<SonyMobileSession.Asset> listPhotos(SonyMobileSession.Device device) throws IOException {
        if(!opened) throw new IOException("Legacy import session not open");
        objects.clear();
        List<SonyMobileSession.Asset> result=new ArrayList<>();
        for(SonyTetherSession.LegacyObject object:transport.listLegacyPhotos()) {
            SonyMobileSession.Asset asset = new SonyMobileSession.Asset(this, object.storage, object.handle,
                object.name, object.size, createdTime(object.created, TimeZone.getDefault()), "legacy:" + object.storage,
                createdTime(object.created, TimeZone.getTimeZone("GMT")), object.key());
            objects.put(asset,object);result.add(asset);
        }
        return result;
    }

    private SonyTetherSession.LegacyObject original(SonyMobileSession.Asset asset) throws IOException {
        if(asset==null || asset.owner!=this || !objects.containsKey(asset)) throw new IOException("Legacy asset outside this session");
        return objects.get(asset);
    }

    @Override public byte[] preview(SonyMobileSession.Asset asset,boolean large) throws IOException {
        try { return transport.previewLegacy(original(asset)); }
        catch(SonyTetherSession.RemoteResponseException unavailable) { throw new SonyMobileSession.ResponseException(unavailable.operation,unavailable.code); }
    }

    @Override public String download(SonyMobileSession.Device device,SonyMobileSession.Asset asset,OutputStream destination,SonyMobileSession.Progress progress) throws IOException {
        SonyTetherSession.LegacyObject object=original(asset);
        OutputStream counted=new FilterOutputStream(destination) {
            long count;
            @Override public void write(byte[] bytes,int offset,int length) throws IOException {
                out.write(bytes,offset,length);count+=length;if(progress!=null) progress.transferred(count,asset.size);
            }
        };
        return transport.downloadLegacyWhole(object,counted);
    }

    static long createdTime(String value,TimeZone zone) {
        if(value.length()<15) return 0;
        SimpleDateFormat format=new SimpleDateFormat("yyyyMMdd'T'HHmmss",Locale.ROOT);format.setLenient(false);
        // Preserve the existing locator while comparing legacy capture dates on the camera clock.
        format.setTimeZone(zone);
        ParsePosition position=new ParsePosition(0);Date date=format.parse(value.substring(0,15),position);
        return date!=null && position.getIndex()==15?date.getTime():0;
    }

    /** 串行调度器在切回遥控前退出内容模式；跨线程取消仍用不等待网络的 close。 */
    public void finish() throws IOException {
        try { if(opened && transport.isOpen()) transport.leaveLegacyContents(); }
        finally { close(); }
    }

    @Override public void close() { transport.close();identified=false;opened=false;objects.clear(); }
}
