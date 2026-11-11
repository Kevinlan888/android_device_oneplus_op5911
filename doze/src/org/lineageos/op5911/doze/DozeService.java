/*
 * Copyright (C) 2026 The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 */

package org.lineageos.op5911.doze;

import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.os.IBinder;
import android.os.PowerManager;
import android.os.SystemClock;
import android.os.UserHandle;
import android.provider.Settings;
import android.util.Log;

/**
 * SystemUI only knows the standard TYPE_PICK_UP_GESTURE, which this device
 * does not have. The oplus sensor hub exposes its own wake-up "pickup" sensor
 * (android.sensor.pickup_detect, type 65611) instead. While the screen is off,
 * listen to it and ask SystemUI for an ambient display pulse.
 *
 * Event values (measured on device): values[0] is 0 when the phone is lifted
 * and 1 when it is put back down; values[1] is just a running counter.
 *
 * Gated by the stock "Lift to check phone" toggle (Settings.Secure
 * doze_pick_up_gesture), which Settings shows because the framework overlay
 * sets config_dozePulsePickup. SystemUI does its own proximity check before
 * pulsing, so pocket triggers are filtered there.
 */
public class DozeService extends Service {
    private static final String TAG = "OplusDoze";

    private static final String PICKUP_SENSOR_TYPE = "android.sensor.pickup_detect";
    private static final String PULSE_ACTION = "com.android.systemui.doze.pulse";
    private static final String SYSTEMUI_PACKAGE = "com.android.systemui";

    // Settings.Secure keys (hidden constants)
    private static final String DOZE_ENABLED = "doze_enabled";
    private static final String DOZE_PICK_UP_GESTURE = "doze_pick_up_gesture";

    // values[0] when the phone is lifted (1 = put down again)
    private static final float VALUE_LIFTED = 0.0f;

    private static final long MIN_PULSE_INTERVAL_MS = 2500;

    private SensorManager mSensorManager;
    private PowerManager mPowerManager;
    private Sensor mPickupSensor;
    private boolean mListening;
    private long mLastPulseTime;

    private final SensorEventListener mPickupListener = new SensorEventListener() {
        @Override
        public void onSensorChanged(SensorEvent event) {
            float value = event.values.length > 0 ? event.values[0] : -1;
            if (Log.isLoggable(TAG, Log.DEBUG)) Log.d(TAG, "pickup event value=" + value);
            if (value != VALUE_LIFTED) return;
            pulse();
        }

        @Override
        public void onAccuracyChanged(Sensor sensor, int accuracy) {}
    };

    private final BroadcastReceiver mScreenReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            if (Intent.ACTION_SCREEN_OFF.equals(intent.getAction())) {
                onScreenOff();
            } else if (Intent.ACTION_SCREEN_ON.equals(intent.getAction())) {
                onScreenOn();
            }
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        mSensorManager = getSystemService(SensorManager.class);
        mPowerManager = getSystemService(PowerManager.class);
        mPickupSensor = findSensor(PICKUP_SENSOR_TYPE);
        if (mPickupSensor == null) {
            Log.w(TAG, "No " + PICKUP_SENSOR_TYPE + " sensor, nothing to do");
            stopSelf();
            return;
        }
        Log.i(TAG, "Using " + mPickupSensor);

        IntentFilter filter = new IntentFilter();
        filter.addAction(Intent.ACTION_SCREEN_ON);
        filter.addAction(Intent.ACTION_SCREEN_OFF);
        registerReceiver(mScreenReceiver, filter);

        if (!mPowerManager.isInteractive()) {
            onScreenOff();
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        if (mPickupSensor != null) {
            unregisterReceiver(mScreenReceiver);
            setListening(false);
        }
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private void onScreenOff() {
        setListening(pickupEnabled());
    }

    private void onScreenOn() {
        setListening(false);
    }

    private boolean pickupEnabled() {
        // Same defaults as AmbientDisplayConfiguration: both default on.
        boolean dozeEnabled = Settings.Secure.getIntForUser(getContentResolver(),
                DOZE_ENABLED, 1, UserHandle.USER_CURRENT) != 0;
        boolean pickup = Settings.Secure.getIntForUser(getContentResolver(),
                DOZE_PICK_UP_GESTURE, getPickupDefault() ? 1 : 0,
                UserHandle.USER_CURRENT) != 0;
        return dozeEnabled && pickup;
    }

    private boolean getPickupDefault() {
        int id = getResources().getIdentifier("config_dozePickupGestureEnabled", "bool",
                "android");
        return id == 0 || getResources().getBoolean(id);
    }

    private void setListening(boolean listen) {
        if (listen == mListening) return;
        if (listen) {
            mSensorManager.registerListener(mPickupListener, mPickupSensor,
                    SensorManager.SENSOR_DELAY_NORMAL);
        } else {
            mSensorManager.unregisterListener(mPickupListener);
        }
        mListening = listen;
        if (Log.isLoggable(TAG, Log.DEBUG)) Log.d(TAG, "listening=" + listen);
    }

    private void pulse() {
        long now = SystemClock.elapsedRealtime();
        if (now - mLastPulseTime < MIN_PULSE_INTERVAL_MS) return;
        if (mPowerManager.isInteractive()) return;
        mLastPulseTime = now;
        Log.i(TAG, "pickup -> ambient pulse");
        Intent intent = new Intent(PULSE_ACTION);
        intent.setPackage(SYSTEMUI_PACKAGE);
        sendBroadcastAsUser(intent, UserHandle.CURRENT);
    }

    private Sensor findSensor(String type) {
        for (Sensor s : mSensorManager.getSensorList(Sensor.TYPE_ALL)) {
            if (type.equals(s.getStringType())) return s;
        }
        return null;
    }
}
