#!/usr/bin/env python3
"""
Zanjir Admin Panel
Simple web-based admin interface for Conduit Matrix server
"""

import os
import sqlite3
import requests
from datetime import datetime
from functools import wraps
from flask import Flask, render_template, request, redirect, url_for, session, flash, jsonify
from dotenv import load_dotenv
from werkzeug.middleware.proxy_fix import ProxyFix

load_dotenv('../.env')

app = Flask(__name__)
app.wsgi_app = ProxyFix(app.wsgi_app, x_prefix=1)
app.secret_key = os.getenv('REGISTRATION_SHARED_SECRET', 'change-me-in-production')

# Configuration
CONDUIT_URL = os.getenv('CONDUIT_URL', 'http://conduit:6167')
ADMIN_SECRET = os.getenv('REGISTRATION_SHARED_SECRET')
DOMAIN = os.getenv('DOMAIN', 'localhost')

# Initialize audit log database
def init_db():
    conn = sqlite3.connect('audit_log.db')
    c = conn.cursor()
    c.execute('''
        CREATE TABLE IF NOT EXISTS audit_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            admin_user TEXT NOT NULL,
            action TEXT NOT NULL,
            target_user TEXT,
            details TEXT,
            ip_address TEXT
        )
    ''')
    conn.commit()
    conn.close()

init_db()

# Log audit action
def log_audit(action, target_user=None, details=None):
    conn = sqlite3.connect('audit_log.db')
    c = conn.cursor()
    c.execute('''
        INSERT INTO audit_log (timestamp, admin_user, action, target_user, details, ip_address)
        VALUES (?, ?, ?, ?, ?, ?)
    ''', (
        datetime.utcnow().isoformat(),
        session.get('username', 'unknown'),
        action,
        target_user,
        details,
        request.remote_addr
    ))
    conn.commit()
    conn.close()

# Authentication decorator
def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if 'logged_in' not in session:
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated_function

# Routes
@app.route('/')
def index():
    if 'logged_in' in session:
        return redirect(url_for('dashboard'))
    return redirect(url_for('login'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = request.form.get('username')
        password = request.form.get('password')
        
        # Authenticate via Conduit
        try:
            response = requests.post(
                f'{CONDUIT_URL}/_matrix/client/v3/login',
                json={
                    'type': 'm.login.password',
                    'identifier': {
                        'type': 'm.id.user',
                        'user': username
                    },
                    'password': password
                }
            )
            
            if response.status_code == 200:
                data = response.json()
                # Check if user is admin
                user_id = data.get('user_id', '')
                
                # Simple admin check - you may want to make this more sophisticated
                if username.endswith('-admin') or check_if_admin(user_id):
                    session['logged_in'] = True
                    session['username'] = username
                    session['access_token'] = data.get('access_token')
                    log_audit('LOGIN', details='Admin logged in successfully')
                    flash('Logged in successfully!', 'success')
                    return redirect(url_for('dashboard'))
                else:
                    flash('Access denied. Admin privileges required.', 'danger')
            else:
                flash('Invalid credentials', 'danger')
        except Exception as e:
            flash(f'Login error: {str(e)}', 'danger')
    
    return render_template('login.html')

def check_if_admin(user_id):
    """Check if user has admin privileges via Conduit API"""
    # This is a placeholder - implement actual admin check
    # You might need to query Conduit's database or use admin API
    return True  # For now, allow anyone who can login

@app.route('/logout')
def logout():
    username = session.get('username', 'unknown')
    log_audit('LOGOUT', details=f'Admin {username} logged out')
    session.clear()
    flash('Logged out successfully', 'info')
    return redirect(url_for('login'))

@app.route('/dashboard')
@login_required
def dashboard():
    # Get basic stats
    stats = {
        'total_users': 0,
        'active_users': 0,
        'total_rooms': 0
    }
    
    try:
        # These would need actual Conduit admin API calls
        # For now, return placeholder data
        stats = get_server_stats()
    except Exception as e:
        flash(f'Error loading stats: {str(e)}', 'warning')
    
    return render_template('dashboard.html', stats=stats)

@app.route('/users')
@login_required
def users():
    # List all users
    try:
        user_list = get_all_users()
        return render_template('users.html', users=user_list)
    except Exception as e:
        flash(f'Error loading users: {str(e)}', 'danger')
        return redirect(url_for('dashboard'))

@app.route('/users/disable/<user_id>', methods=['POST'])
@login_required
def disable_user(user_id):
    try:
        # Call Conduit admin API to disable user
        # This is a placeholder - implement actual API call
        log_audit('DISABLE_USER', target_user=user_id, details='User account disabled')
        flash(f'User {user_id} disabled successfully', 'success')
    except Exception as e:
        flash(f'Error disabling user: {str(e)}', 'danger')
    
    return redirect(url_for('users'))

@app.route('/users/delete/<user_id>', methods=['POST'])
@login_required
def delete_user(user_id):
    try:
        # Call Conduit admin API to delete user
        # This is a placeholder - implement actual API call
        log_audit('DELETE_USER', target_user=user_id, details='User account deleted')
        flash(f'User {user_id} deleted successfully', 'success')
    except Exception as e:
        flash(f'Error deleting user: {str(e)}', 'danger')
    
    return redirect(url_for('users'))

@app.route('/logs')
@login_required
def logs():
    conn = sqlite3.connect('audit_log.db')
    c = conn.cursor()
    c.execute('SELECT * FROM audit_log ORDER BY timestamp DESC LIMIT 100')
    log_entries = c.fetchall()
    conn.close()
    
    return render_template('logs.html', logs=log_entries)

# Helper functions (placeholders)
def get_server_stats():
    """Get server statistics from Conduit"""
    # Implement actual API calls here
    return {
        'total_users': 0,
        'active_users': 0,
        'total_rooms': 0
    }

def get_all_users():
    """Get list of all users from Conduit"""
    # Implement actual API calls here
    return []

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
