package app.rawlab.cameraconnect;

import android.app.Activity;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.Network;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.widget.*;
import com.rawlab.android.camera.protocol.SonyMobileSession;
import com.rawlab.android.camera.protocol.SonyTetherSession;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

/** 有明确退出和原件校验的设备实验面板，不是正式产品入口。 */
final class TetherExperiment {
    private final Activity activity;
    private final SonyMobileSession.Reporter report;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ScheduledExecutorService worker = Executors.newSingleThreadScheduledExecutor();
    private final Object ownership = new Object();
    private final Set<String> seen = new HashSet<>();
    private final Map<String,SavedOriginal> savedOriginals = new LinkedHashMap<>();
    private final AtomicBoolean framePending = new AtomicBoolean();
    private final ImageView live;
    private final TextView status;
    private final Button shutter;
    private volatile SonyTetherSession session;
    private HttpURLConnection stream;
    private ScheduledFuture<?> watching;
    private volatile int generation;
    private Network network;
    private InetAddress camera;
    private UUID guid;
    private int savedCount;
    private int contentsWaits;
    private volatile SonyMobileSession verification;
    private static final class SavedOriginal {
        final SonyMobileSession.Asset source;final String digest;
        SavedOriginal(SonyMobileSession.Asset source,String digest) { this.source=source;this.digest=digest; }
    }

    TetherExperiment(Activity activity, LinearLayout root, SonyMobileSession.Reporter report) {
        this.activity=activity; this.report=report;
        status=new TextView(activity); status.setText("遥控实验等待相机连接；不会自动按快门。"); root.addView(status);
        live=new ImageView(activity); live.setScaleType(ImageView.ScaleType.FIT_CENTER);
        live.setContentDescription("相机实时取景实验画面");
        root.addView(live,new LinearLayout.LayoutParams(-1,0,1));
        LinearLayout actions=new LinearLayout(activity);
        shutter=new Button(activity); shutter.setText("遥控单拍一次"); shutter.setEnabled(false);
        shutter.setOnClickListener(v -> capture()); actions.addView(shutter,new LinearLayout.LayoutParams(0,-2,1));
        Button verify=new Button(activity); verify.setText("停止并独立校验原件");
        verify.setOnClickListener(v -> verifyOriginals()); actions.addView(verify,new LinearLayout.LayoutParams(0,-2,1)); root.addView(actions);
    }

    void connect(Network selected,InetAddress address) {
        stop(); network=selected; camera=address; guid=UUID.randomUUID();
        int current=generation;
        status.setText("正在核对遥控会话…");
        worker.execute(() -> {
            SonyTetherSession opened=null;
            try {
                if(current!=generation) return;
                savedOriginals.clear();savedCount=0;contentsWaits=0;
                opened=new SonyTetherSession(selected.getSocketFactory(),address,guid,message -> log(current,message));
                synchronized(ownership) {
                    if (current!=generation) { opened.close(); return; }
                    session=opened;
                }
                opened.connectRemote();
                Map<Integer,SonyTetherSession.Property> properties=opened.properties();
                for (int code:new int[]{0xd20c,0xd213,0xd215,0xd222,0xd268,0x5013,0x500a}) {
                    SonyTetherSession.Property p=properties.get(code);
                    if (p!=null) log(current,String.format(Locale.ROOT,"remote_property code=0x%04x type=0x%04x value=%d enabled=%d",code,p.type,p.number(),p.enabled));
                }
                List<SonyMobileSession.Asset> baseline=opened.listPhotos();
                seen.clear(); for (SonyMobileSession.Asset item:baseline) seen.add(item.key());
                log(current,"remote_watch_armed baseline_files="+baseline.size());
                SonyTetherSession.Property url=properties.get(0xd278);
                if (url!=null && !url.text().isEmpty()) startLive(current,selected,SonyTetherSession.liveViewURL(url.text(),address));
                else log(current,"remote_live_url_missing");
                main.post(() -> { if(current==generation) { status.setText("遥控会话已就绪；正在监视新照片。可用手机或机身单拍。"); shutter.setEnabled(true); } });
                synchronized(ownership) {
                    if(current==generation) watching=worker.scheduleWithFixedDelay(() -> watch(current),2,2,TimeUnit.SECONDS);
                }
            } catch(Exception error) {
                if(opened!=null) opened.close();
                failure(current,"remote_connect_failed",error);
            }
        });
    }

    private void startLive(int current,Network selected,URL url) {
        new Thread(() -> {
            HttpURLConnection connection=null;
            try {
                connection=(HttpURLConnection)selected.openConnection(url);
                connection.setInstanceFollowRedirects(false); connection.setConnectTimeout(5000); connection.setReadTimeout(5000);
                synchronized(ownership) { if(current!=generation) { connection.disconnect();return; } stream=connection; }
                if(connection.getResponseCode()!=200) throw new IOException("Live view HTTP "+connection.getResponseCode());
                int frames=0; long lastShown=0;
                try(InputStream input=connection.getInputStream()) {
                    while(current==generation) {
                        byte[] jpeg=SonyTetherSession.readFrame(input); frames++;
                        long now=SystemClock.elapsedRealtime();
                        if(now-lastShown<100 || !framePending.compareAndSet(false,true)) continue;
                        lastShown=now;
                        BitmapFactory.Options dimensions=new BitmapFactory.Options(); dimensions.inJustDecodeBounds=true;
                        BitmapFactory.decodeByteArray(jpeg,0,jpeg.length,dimensions);
                        if(dimensions.outWidth<=0 || dimensions.outHeight<=0 || (long)dimensions.outWidth*dimensions.outHeight>16000000) {
                            framePending.set(false); throw new IOException("Invalid live-view dimensions");
                        }
                        BitmapFactory.Options options=new BitmapFactory.Options();
                        while(dimensions.outWidth/(options.inSampleSize==0?1:options.inSampleSize)>1920) options.inSampleSize=options.inSampleSize==0?2:options.inSampleSize*2;
                        Bitmap bitmap=BitmapFactory.decodeByteArray(jpeg,0,jpeg.length,options);
                        if(bitmap==null) { framePending.set(false);throw new IOException("Live frame decode failed"); }
                        int number=frames;
                        main.post(() -> {
                            if(current==generation) { live.setImageBitmap(bitmap); if(number==1 || number%100==0) report.report("remote_live_frame number="+number+" width="+bitmap.getWidth()+" height="+bitmap.getHeight()); }
                            else bitmap.recycle();
                            framePending.set(false);
                        });
                    }
                }
            } catch(Exception error) {
                // HTTP 异常可能包含带会话参数的完整 URL，日志和界面只保留异常类别。
                failure(current,"remote_live_failed",new IOException(error.getClass().getSimpleName()));
            }
            finally {
                if(connection!=null) connection.disconnect();
                synchronized(ownership) { if(stream==connection) stream=null; }
            }
        },"camera-tether-live").start();
    }

    private void capture() {
        final int current=generation; final SonyTetherSession active=session;
        if(active==null || !shutter.isEnabled()) return;
        shutter.setEnabled(false); status.setText("正在请求单拍；失败时不会自动重拍。");
        worker.execute(() -> {
            try { if(current!=generation) return; active.capture(); watch(current); }
            catch(Exception error) { failure(current,"remote_capture_failed",error); }
            finally { main.post(() -> { if(current==generation) shutter.setEnabled(contentsWaits==0); }); }
        });
    }

    private void watch(int current) {
        if(current!=generation || session==null) return;
        try {
            List<SonyMobileSession.Asset> listed=session.listPhotos();
            if(contentsWaits>0) {
                contentsWaits=0; log(current,"remote_contents_available_again");
                main.post(() -> { if(current==generation) { shutter.setEnabled(true);status.setText("相机已恢复读卡，继续监视新照片。"); } });
            }
            List<SonyMobileSession.Asset> fresh=new ArrayList<>(); for(SonyMobileSession.Asset photo:listed) if(!seen.contains(photo.key())) fresh.add(photo);
            if(fresh.size()>16) throw new IOException("Too many new files for the bounded single-shot experiment");
            for(SonyMobileSession.Asset photo:fresh) {
                if(current!=generation) return;
                log(current,"remote_new_card_file "+photo.name+" bytes="+photo.size);
                File directory=new File(activity.getFilesDir(),"tether-originals"); directory.mkdirs();
                File partial=new File(directory,UUID.randomUUID()+".part");
                try {
                    String digest;
                    try(FileOutputStream output=new FileOutputStream(partial)) { digest=session.download(photo,output);output.getFD().sync(); }
                    File complete=new File(directory,digest+"-"+photo.name);
                    synchronized(ownership) {
                        if(current!=generation) return;
                        if(!partial.renameTo(complete)) throw new IOException("Cannot publish experiment original");
                        savedOriginals.put(photo.key(),new SavedOriginal(photo,digest)); seen.add(photo.key()); savedCount++;
                    }
                    log(current,"remote_original_saved name="+photo.name+" bytes="+photo.size+" sha256="+digest+" file="+complete.getName());
                    main.post(() -> { if(current==generation) status.setText("实验原件已保存 "+savedCount+" 个文件；继续监视机身单拍。"); });
                } finally { if(partial.exists()) partial.delete(); }
            }
        } catch(SonyTetherSession.RemoteResponseException response) {
            if(response.operation==0x923c && (response.code==0x2005 || response.code==0x2019) && ++contentsWaits<=120) {
                if(contentsWaits==1) {
                    log(current,"remote_contents_temporarily_unavailable code="+response.code);
                    main.post(() -> { if(current==generation) { shutter.setEnabled(false);status.setText("相机暂不能列出照片；退出机身菜单后自动重试读取。"); } });
                }
            } else {
                synchronized(ownership) { if(watching!=null) watching.cancel(false); }
                failure(current,"remote_watch_failed",response);
            }
        } catch(Exception error) {
            synchronized(ownership) { if(watching!=null) watching.cancel(false); }
            failure(current,"remote_watch_failed",error);
        }
    }

    void verifyOriginals() {
        Network selected=network; InetAddress address=camera;
        stop(); final int current=generation;
        if(selected==null || address==null) return;
        status.setText("遥控已停止，使用原有只读传图协议独立比较原件…");
        worker.execute(() -> {
            if(current!=generation) return;
            if(savedOriginals.isEmpty()) { log(current,"remote_verify_no_originals");return; }
            try(SonyMobileSession independent=new SonyMobileSession(selected.getSocketFactory(),address,UUID.randomUUID(),message -> log(current,message))) {
                synchronized(ownership) { if(current!=generation) { independent.close();return; } verification=independent; }
                SonyMobileSession.Device info=independent.deviceInfo(); independent.openSession();
                List<SonyMobileSession.Asset> objects=independent.listPhotos(info);
                for(SavedOriginal saved:new LinkedHashMap<>(savedOriginals).values()) {
                    SonyMobileSession.Asset match=null;
                    for(SonyMobileSession.Asset item:objects) if(item.key().equals(saved.source.key())) { if(match!=null) throw new IOException("Ambiguous original identity");match=item; }
                    if(match==null) throw new IOException("Original no longer listed");
                    String digest=independent.download(info,match,new OutputStream() { public void write(int ignored) {} public void write(byte[] ignored,int start,int count) {} });
                    if(!digest.equals(saved.digest)) throw new IOException("Original byte comparison failed");
                    log(current,"remote_original_independently_verified name="+match.name+" bytes="+match.size+" sha256="+digest);
                }
                main.post(() -> { if(current==generation) status.setText("只读传图协议独立校验通过："+savedOriginals.size()+" 个原件 SHA-256 一致。"); });
            } catch(Exception error) { failure(current,"remote_verify_failed",error); }
            finally { synchronized(ownership) { if(current==generation) verification=null; } }
        });
    }

    boolean stop() {
        boolean releasing=false;
        synchronized(ownership) {
            generation++;
            if(watching!=null) { watching.cancel(false);watching=null; }
            if(session!=null) { session.requestStop();releasing=session.isOpen();session=null; }
            if(verification!=null) { verification.close();verification=null; }
            if(stream!=null) { stream.disconnect();stream=null; }
        }
        shutter.setEnabled(false); live.setImageDrawable(null);
        return releasing;
    }
    void destroy() { stop();worker.shutdownNow(); }
    private void log(int current,String message) { main.post(() -> { if(current==generation) report.report(message); }); }
    private void failure(int current,String stage,Exception error) {
        main.post(() -> { if(current==generation) {
            report.report(stage+" "+error.getClass().getSimpleName()+" "+error.getMessage());
            if(stage.equals("remote_connect_failed") || stage.equals("remote_watch_failed") || session!=null && !session.isOpen()) stop();
            status.setText(stage+"："+error.getMessage());
        } });
    }
}
