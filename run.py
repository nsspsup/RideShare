from app import create_app, db
app = create_app()

# with app.app_context():
#     db.drop_all()   # Optional, for safety
#     db.create_all()


if __name__ == '__main__':
    app.run(debug=True)
