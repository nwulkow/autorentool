from PIL import Image

def make_white_transparent(image_path, output_path):
    img = Image.open(image_path).convert("RGBA")
    datas = img.getdata()
    
    new_data = []
    for item in datas:
        # Check if the pixel is white or close to white
        if item[0] > 240 and item[1] > 240 and item[2] > 240:
            # Change all white (also shades of whites)
            # pixels to transparent
            new_data.append((255, 255, 255, 0))
        else:
            new_data.append(item)
            
    img.putdata(new_data)
    img.save(output_path, "PNG")

make_white_transparent('logo.png', 'logo.png')
